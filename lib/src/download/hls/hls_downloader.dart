import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../log.dart';
import '../http/http_client.dart';
import '../http/url_refresher.dart';
import 'aes_decryptor.dart';
import 'm3u8_parser.dart';

void _noop(int done, int total) {}

/// HLS 下载结果：交给 remux 步骤的有序分片文件 + 最终（可能被刷新过的）入口地址。
class HlsDownloadResult {
  /// 解密后的分片绝对路径，按播放列表顺序（seg_0.ts, seg_1.ts, ...）。
  final List<String> segmentFiles;

  /// 成功那次所用的入口 m3u8 地址（发生过刷新时为新地址）。
  final String finalEntryUrl;

  const HlsDownloadResult({
    required this.segmentFiles,
    required this.finalEntryUrl,
  });
}

/// HLS 分片下载器：解析 m3u8 → 并发下 ts → 整片 AES-128 解密 → 原子落 `seg_<n>.ts`。
///
/// 稳定性核心：
/// - **磁盘推导续传**：`seg_<n>.ts` 已存在且非空即视为完成，跳过下载。
/// - **原子写**：先写 `.tmp` 再 rename，崩溃中断不会留下半片被误当完成。
/// - **URL 过期重映射**：入口/变体/key/分片任一 404/410 → 刷新入口 → 重解析新 playlist →
///   按分片索引续下剩余片（磁盘已有的自动跳过）。刷新次数有上限防死循环。
/// - 取消（CancelToken）立即冒泡，不刷新不重试。
class HlsDownloader {
  final HttpClient _http;
  final UrlRefresher _refresher;
  final M3u8Parser _parser;
  final AesDecryptor _aes;
  final int _segConcurrency;

  /// 单次 download 调用内最多追随几次 URL 刷新，超过则以底层错误放弃。
  static const int _maxRefreshes = 5;

  HlsDownloader({
    required HttpClient http,
    required UrlRefresher refresher,
    M3u8Parser? parser,
    AesDecryptor? aes,
    int segConcurrency = 2,
  })  : _http = http,
        _refresher = refresher,
        _parser = parser ?? M3u8Parser(),
        _aes = aes ?? AesDecryptor(),
        _segConcurrency = segConcurrency < 1 ? 1 : segConcurrency;

  Future<HlsDownloadResult> download({
    required String taskId,
    required String entryUrl,
    required String dir,
    void Function(int done, int total) onProgress = _noop,
    CancelToken? cancelToken,
  }) async {
    Directory(dir).createSync(recursive: true);

    var currentEntry = entryUrl;
    var refreshes = 0;
    // 首次解析确定的期望分片总数：跨刷新保持不变，用于兜底"刷新后 playlist 变短"。
    int? expectedTotal;

    while (true) {
      try {
        final media = await _resolveMediaPlaylist(currentEntry, cancelToken);
        final segments = media.segments;
        if (segments.isEmpty) {
          throw StateError('HLS media playlist 无分片: $currentEntry');
        }
        // 已知边界：按 VOD 假设——同一内容跨刷新分片数/顺序稳定、MEDIA-SEQUENCE 不变
        // （隐式 IV 依赖 mediaSequence 稳定，见 _downloadSegments）。expectedTotal 锁定
        // 首次解析的分片数：刷新后 playlist 变长时只取前 expectedTotal 个（多出的忽略），
        // 变短则走下方致命校验。直播/滑动窗口播放列表不在支持范围内。
        expectedTotal ??= segments.length;
        final total = expectedTotal;

        // 刷新后的 playlist 分片数变少：缺失且磁盘也没有的索引视为致命，不产出截断视频。
        if (segments.length < total) {
          for (var i = segments.length; i < total; i++) {
            if (!_segDone(dir, i)) {
              throw StateError(
                  '刷新后的 playlist 分片数(${segments.length}) < 预期($total)，索引 $i 缺失');
            }
          }
        }

        final key = media.key;
        final encrypted =
            key != null && key.method == 'AES-128' && key.uri != null;
        FfmpegRemuxLog.d('hls',
            '[$taskId] playlist: ${segments.length} 片, 加密=$encrypted');
        List<int>? keyBytes;
        if (encrypted) {
          keyBytes = await _http.getBytes(key.uri!, cancelToken: cancelToken);
          if (keyBytes.length != 16) {
            throw StateError('AES-128 key 长度非法: ${keyBytes.length} 字节');
          }
        }

        await _downloadSegments(
          dir: dir,
          segments: segments,
          total: total,
          keyBytes: keyBytes,
          key: key,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );

        final files = [for (var i = 0; i < total; i++) _segPath(dir, i)];
        FfmpegRemuxLog.d('hls', '[$taskId] 下载完成: $total 片');
        return HlsDownloadResult(
          segmentFiles: files,
          finalEntryUrl: currentEntry,
        );
      } on UrlExpiredException catch (e) {
        // 与 404 竞争时若已取消：不再刷新，立即让取消生效。
        _throwIfCancelled(cancelToken);
        if (refreshes >= _maxRefreshes) {
          FfmpegRemuxLog.d(
              'hls', '[$taskId] 刷新次数超上限($_maxRefreshes)，放弃');
          rethrow;
        }
        refreshes++;
        FfmpegRemuxLog.d(
            'hls',
            '[$taskId] ${e.statusCode} ${e.url} -> '
            '刷新入口（第 $refreshes/$_maxRefreshes 次）');
        currentEntry = await _refresher.refresh(taskId);
      }
    }
  }

  /// 取入口 m3u8，若为 master 则跟随 bestVariant 跳一次到 media playlist。
  Future<M3u8Playlist> _resolveMediaPlaylist(
    String entryUrl,
    CancelToken? cancelToken,
  ) async {
    final entryBytes = await _http.getBytes(entryUrl, cancelToken: cancelToken);
    var playlist =
        _parser.parse(_decodeText(entryBytes), baseUri: entryUrl);

    if (playlist.isMaster) {
      final variant = playlist.bestVariant;
      if (variant == null) {
        throw StateError('HLS master playlist 无可用变体: $entryUrl');
      }
      final mediaBytes =
          await _http.getBytes(variant.uri, cancelToken: cancelToken);
      playlist = _parser.parse(_decodeText(mediaBytes), baseUri: variant.uri);
    }
    return playlist;
  }

  /// 并发（上限 [_segConcurrency]）下剩余分片：下载 → 解密 → 原子落盘。
  ///
  /// 任一分片命中 404/410 时，所有 worker 优雅收尾（保留已下好的分片），再抛
  /// [UrlExpiredException] 触发上层刷新重映射。取消/其它错误同样先收尾再冒泡。
  Future<void> _downloadSegments({
    required String dir,
    required List<HlsSegment> segments,
    required int total,
    required List<int>? keyBytes,
    required HlsKey? key,
    required void Function(int done, int total) onProgress,
    required CancelToken? cancelToken,
  }) async {
    var done = 0;
    for (var i = 0; i < total; i++) {
      if (_segDone(dir, i)) done++;
    }
    onProgress(done, total);

    final pending = [
      for (final s in segments)
        if (!_segDone(dir, s.index)) s
    ];
    if (pending.isEmpty) return;

    var next = 0;
    var aborted = false;
    UrlExpiredException? expired;
    Object? fatal;
    StackTrace? fatalStack;

    Future<void> worker() async {
      while (!aborted) {
        _throwIfCancelled(cancelToken);
        if (next >= pending.length) return;
        final seg = pending[next++];
        try {
          final bytes =
              await _http.getBytes(seg.uri, cancelToken: cancelToken);
          // 空 body（如 CDN 异常 200 空响应）不能当成功：否则会落 0 字节 seg 文件，
          // 既污染产物又让下次 resume 判为未完成，前后不一致。视为该分片失败。
          if (bytes.isEmpty) {
            throw StateError('HLS 分片返回空 body: ${seg.uri}');
          }
          final data = (keyBytes != null && key != null)
              ? _aes.decrypt(
                  bytes,
                  key: keyBytes,
                  iv: key.ivHex != null
                      ? AesDecryptor.ivFromHex(key.ivHex!)
                      : AesDecryptor.ivFromSequence(seg.mediaSequence),
                )
              : Uint8List.fromList(bytes);
          await _writeAtomic(_segPath(dir, seg.index), data);
          done++;
          onProgress(done, total);
        } on UrlExpiredException catch (e) {
          aborted = true;
          expired = e;
          return;
        } catch (e, st) {
          aborted = true;
          fatal = e;
          fatalStack = st;
          return;
        }
      }
    }

    final workers = [
      for (var i = 0; i < _segConcurrency && i < pending.length; i++) worker()
    ];
    await Future.wait(workers);

    if (fatal != null) {
      Error.throwWithStackTrace(fatal!, fatalStack!);
    }
    if (expired != null) throw expired!;
  }

  /// 原子写：先写 `.tmp` 并 flush，再 rename 到目标；rename 是同名同盘的原子操作。
  Future<void> _writeAtomic(String path, List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  bool _segDone(String dir, int index) {
    final f = File(_segPath(dir, index));
    return f.existsSync() && f.lengthSync() > 0;
  }

  String _segPath(String dir, int index) => p.join(dir, 'seg_$index.ts');

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken != null && cancelToken.isCancelled) {
      throw cancelToken.cancelError ??
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
          );
    }
  }

  /// m3u8/key 均为文本或字节，解析器只吃 UTF-8 文本，这里做一次宽松解码。
  String _decodeText(List<int> bytes) => String.fromCharCodes(bytes);
}
