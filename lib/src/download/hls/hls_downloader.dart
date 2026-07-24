import 'dart:convert';
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
  /// 分片绝对路径，按播放列表顺序。明文片为 `seg_<n>.ts`，
  /// 加密片为原样落盘的密文 `seg_<n>.ts.enc`（解密后置到 remux 阶段）。
  final List<String> segmentFiles;

  /// 成功那次所用的入口 m3u8 地址（发生过刷新时为新地址）。
  final String finalEntryUrl;

  /// AES-128 key（16 字节）；playlist 未加密时为 null。
  final Uint8List? key;

  /// `.enc` 密文分片路径 → 其 16 字节 IV；明文分片不在表内。
  /// key/IV 对应最终成功那次尝试所解析的 playlist。
  final Map<String, Uint8List> ivByPath;

  const HlsDownloadResult({
    required this.segmentFiles,
    required this.finalEntryUrl,
    this.key,
    this.ivByPath = const {},
  });
}

/// HLS 分片下载器：解析 m3u8 → 并发下 ts → 原子落盘。下载阶段是纯网络 IO：
/// 加密分片不解密、密文原样落 `seg_<n>.ts.enc`，解密后置到 remux worker
/// isolate（与 demux 重叠），避免 CPU 解密卡在抓取环路里压低网络吞吐。
///
/// 稳定性核心：
/// - **磁盘推导续传**：`seg_<n>.ts`（明文/旧版已解密产物）或 `seg_<n>.ts.enc`
///   已存在且非空即视为完成，跳过下载。
/// - **原子写**：先写 `.tmp` 再 rename，崩溃中断不会留下半片被误当完成。
/// - **URL 过期重映射**：入口/变体/key/分片任一 404/410 → 刷新入口 → 重解析新 playlist →
///   按分片索引续下剩余片（磁盘已有的自动跳过）。刷新次数有上限防死循环。
/// - 取消（CancelToken）立即冒泡，不刷新不重试。
class HlsDownloader {
  final HttpClient _http;
  final UrlRefresher _refresher;
  final M3u8Parser _parser;
  final int _segConcurrency;

  /// 单次 download 调用内最多追随几次 URL 刷新，超过则以底层错误放弃。
  static const int _maxRefreshes = 5;

  /// 单个分片遇 5xx（如 CDN 回源超时 504）的额外重试次数。
  /// HTTP 层已做秒级退避重试，这里再加一层「更慢」的分片级重试：源站过载时
  /// 需要更长冷却，且一个分片失败不该直接判整个任务死。
  static const int _segMaxRetries = 3;

  /// 分片级重试的基础退避，按 1×/2×/4× 增长（2s / 4s / 8s）。
  static const Duration _segRetryBackoff = Duration(seconds: 2);

  /// 分片级重试也用尽后，刷新签名 URL 前的冷却时长（给源站喘息）。
  static const Duration _serverCooldown = Duration(seconds: 10);

  HlsDownloader({
    required HttpClient http,
    required UrlRefresher refresher,
    M3u8Parser? parser,
    int segConcurrency = 2,
  })  : _http = http,
        _refresher = refresher,
        _parser = parser ?? M3u8Parser(),
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
    // master 场景首次选定的变体：跨 URL 刷新锁定同一路（带宽/分辨率），
    // 防止刷新后 argmax 选到别的码率、混拼不同码率的分片。
    HlsVariant? lockedVariant;

    while (true) {
      try {
        final (media, chosen) = await _resolveMediaPlaylist(
          currentEntry,
          cancelToken,
          lockedVariant: lockedVariant,
        );
        lockedVariant ??= chosen;
        _ensureSupported(media);
        final segments = media.segments;
        if (segments.isEmpty) {
          throw StateError('HLS media playlist 无分片: $currentEntry');
        }
        // 已知边界：按 VOD 假设——同一内容跨刷新分片数/顺序稳定、MEDIA-SEQUENCE 不变
        // （隐式 IV 依赖 mediaSequence 稳定，见下方 ivByPath 构建）。expectedTotal 锁定
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
        VideoCacherLog.d('hls',
            '[$taskId] playlist: ${segments.length} 片, 加密=$encrypted');
        List<int>? keyBytes;
        if (encrypted) {
          keyBytes = await _http.getBytes(key.uri!, cancelToken: cancelToken);
          if (keyBytes.length != 16) {
            throw StateError('AES-128 key 长度非法: ${keyBytes.length} 字节');
          }
        }

        await _downloadSegments(
          taskId: taskId,
          dir: dir,
          segments: segments,
          total: total,
          encrypted: encrypted,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );

        // 逐索引取实际存在的产物路径（明文优先），密文片配上解密 IV。
        final files = <String>[];
        final ivByPath = <String, Uint8List>{};
        for (var i = 0; i < total; i++) {
          final path = _existingSegPath(dir, i)!; // 下载成功后每索引必有产物
          files.add(path);
          if (keyBytes == null || !path.endsWith('.enc')) continue;
          // 刷新后 playlist 变短时，磁盘遗留的尾部密文片按 VOD 假设
          // （mediaSequence = 首片序号 + 索引）推导隐式 IV。
          final seq = i < segments.length
              ? segments[i].mediaSequence
              : segments.first.mediaSequence + i;
          ivByPath[path] = key!.ivHex != null
              ? AesDecryptor.ivFromHex(key.ivHex!)
              : AesDecryptor.ivFromSequence(seq);
        }
        VideoCacherLog.d('hls', '[$taskId] 下载完成: $total 片');
        return HlsDownloadResult(
          segmentFiles: files,
          finalEntryUrl: currentEntry,
          key: keyBytes == null ? null : Uint8List.fromList(keyBytes),
          ivByPath: ivByPath,
        );
      } on UrlExpiredException catch (e) {
        // 与 404 竞争时若已取消：不再刷新，立即让取消生效。
        _throwIfCancelled(cancelToken);
        if (refreshes >= _maxRefreshes) {
          VideoCacherLog.d(
              'hls', '[$taskId] 刷新次数超上限($_maxRefreshes)，放弃');
          rethrow;
        }
        refreshes++;
        VideoCacherLog.d(
            'hls',
            '[$taskId] ${e.statusCode} ${e.url} -> '
            '刷新入口（第 $refreshes/$_maxRefreshes 次）');
        currentEntry = await _refresher.refresh(taskId);
      } on HttpStatusException catch (e) {
        // 分片级重试已用尽的 5xx：冷却后刷新签名 URL 再战（新签名常路由到
        // 健康边缘节点）。已下好的分片保留，只补缺失的。
        _throwIfCancelled(cancelToken);
        if (e.statusCode < 500 || refreshes >= _maxRefreshes) rethrow;
        refreshes++;
        VideoCacherLog.d(
            'hls',
            '[$taskId] ${e.statusCode} 持续不可用 -> 冷却 ${_serverCooldown.inSeconds}s '
            '后刷新入口重试（第 $refreshes/$_maxRefreshes 次）');
        await Future<void>.delayed(_serverCooldown);
        _throwIfCancelled(cancelToken);
        currentEntry = await _refresher.refresh(taskId);
      }
    }
  }

  /// 不支持的 playlist 特性在下任何分片（含 key）前 fail-fast：否则 key 轮换会
  /// 解错分片、SAMPLE-AES 会落密文、fMP4/BYTERANGE/DISCONTINUITY 会产出
  /// 重复/乱序或无法 remux 的数据，且污染断点续传缓存。
  void _ensureSupported(M3u8Playlist media) {
    if (media.unsupportedKeyMethod != null) {
      throw UnsupportedPlaylistException(
          'playlist 使用 EXT-X-KEY METHOD=${media.unsupportedKeyMethod}，'
          '当前仅支持 NONE/AES-128');
    }
    if (media.hasKeyRotation) {
      throw UnsupportedPlaylistException(
          'playlist 使用多个不同的 EXT-X-KEY（key 轮换），当前仅支持单 key');
    }
    if (media.hasMap) {
      throw UnsupportedPlaylistException(
          'playlist 使用 EXT-X-MAP(fMP4)，当前仅支持 TS 分片');
    }
    if (media.hasByteRange) {
      throw UnsupportedPlaylistException(
          'playlist 使用 EXT-X-BYTERANGE，当前不支持字节区间分片');
    }
    if (media.hasDiscontinuity) {
      throw UnsupportedPlaylistException(
          'playlist 使用 EXT-X-DISCONTINUITY，当前不支持不连续流');
    }
  }

  /// 取入口 m3u8，若为 master 则跟随所选变体跳一次到 media playlist。
  /// 首次（[lockedVariant] 为 null）选带宽最高的一路；刷新后重解析时按锁定
  /// 变体匹配（带宽+分辨率精确命中，否则带宽最接近）。返回 (playlist, 所选变体)。
  Future<(M3u8Playlist, HlsVariant?)> _resolveMediaPlaylist(
    String entryUrl,
    CancelToken? cancelToken, {
    HlsVariant? lockedVariant,
  }) async {
    final entryBytes = await _http.getBytes(entryUrl, cancelToken: cancelToken);
    var playlist =
        _parser.parse(_decodeText(entryBytes), baseUri: entryUrl);
    HlsVariant? chosen;

    if (playlist.isMaster) {
      chosen = lockedVariant == null
          ? playlist.bestVariant
          : _matchVariant(playlist.variants, lockedVariant);
      if (chosen == null) {
        throw StateError('HLS master playlist 无可用变体: $entryUrl');
      }
      final mediaBytes =
          await _http.getBytes(chosen.uri, cancelToken: cancelToken);
      playlist = _parser.parse(_decodeText(mediaBytes), baseUri: chosen.uri);
    }
    return (playlist, chosen);
  }

  /// 在新 master 里找回锁定的那路：带宽+分辨率精确命中优先，否则带宽差最小者。
  static HlsVariant? _matchVariant(
      List<HlsVariant> variants, HlsVariant locked) {
    if (variants.isEmpty) return null;
    for (final v in variants) {
      if (v.bandwidth == locked.bandwidth && v.resolution == locked.resolution) {
        return v;
      }
    }
    return variants.reduce((a, b) =>
        (b.bandwidth - locked.bandwidth).abs() <
                (a.bandwidth - locked.bandwidth).abs()
            ? b
            : a);
  }

  /// 并发（上限 [_segConcurrency]）下剩余分片：下载 → 原子落盘（不解密，
  /// [encrypted] 时密文原样落 `.ts.enc`）。
  ///
  /// 任一分片命中 404/410 时，所有 worker 优雅收尾（保留已下好的分片），再抛
  /// [UrlExpiredException] 触发上层刷新重映射。取消/其它错误同样先收尾再冒泡。
  Future<void> _downloadSegments({
    required String taskId,
    required String dir,
    required List<HlsSegment> segments,
    required int total,
    required bool encrypted,
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
    HttpStatusException? serverError;
    Object? fatal;
    StackTrace? fatalStack;
    var fetchedBytes = 0; // 本次实际下载字节（不含已续传的磁盘残留）
    final sw = Stopwatch()..start();

    // 分片级重试：HTTP 层退避后仍 5xx（源站持续过载）时再等更久重试，
    // 而不是让一个分片直接判死整个任务。404/410、取消按原语义立即冒泡。
    Future<List<int>> fetchSegment(HlsSegment seg) async {
      for (var attempt = 0;; attempt++) {
        try {
          return await _http.getBytes(seg.uri, cancelToken: cancelToken);
        } on HttpStatusException catch (e) {
          if (e.statusCode < 500 || attempt >= _segMaxRetries) rethrow;
          final wait = _segRetryBackoff * (1 << attempt);
          VideoCacherLog.d(
              'hls',
              '[$taskId] 分片 ${seg.index} 返回 ${e.statusCode}，'
              '${wait.inSeconds}s 后重试（${attempt + 1}/$_segMaxRetries）');
          await Future<void>.delayed(wait);
          _throwIfCancelled(cancelToken);
        }
      }
    }

    Future<void> worker() async {
      while (!aborted) {
        _throwIfCancelled(cancelToken);
        if (next >= pending.length) return;
        final seg = pending[next++];
        try {
          final bytes = await fetchSegment(seg);
          // 空 body（如 CDN 异常 200 空响应）不能当成功：否则会落 0 字节 seg 文件，
          // 既污染产物又让下次 resume 判为未完成，前后不一致。视为该分片失败。
          if (bytes.isEmpty) {
            throw StateError('HLS 分片返回空 body: ${seg.uri}');
          }
          final path =
              encrypted ? _encSegPath(dir, seg.index) : _segPath(dir, seg.index);
          await _writeAtomic(path, bytes);
          fetchedBytes += bytes.length;
          done++;
          onProgress(done, total);
        } on UrlExpiredException catch (e) {
          aborted = true;
          expired = e;
          return;
        } on HttpStatusException catch (e) {
          // 分片级重试也用尽的 5xx：源站/边缘节点持续不可用。签名 URL 刷新后
          // 常会路由到健康节点，故按「需刷新」处理而非直接判死整个任务。
          if (e.statusCode >= 500) {
            aborted = true;
            serverError = e;
            return;
          }
          aborted = true;
          fatal = e;
          fatalStack = StackTrace.current;
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
    if (serverError != null) throw serverError!;

    final ms = sw.elapsedMilliseconds;
    final mb = fetchedBytes / (1024 * 1024);
    final mbps = ms > 0 ? mb / (ms / 1000) : 0;
    VideoCacherLog.d(
        'hls',
        '[$taskId] 本轮下载 ${mb.toStringAsFixed(1)}MB / ${ms}ms '
        '= ${mbps.toStringAsFixed(2)}MB/s（并发 $_segConcurrency）');
  }

  /// 原子写：先写 `.tmp` 并 flush，再 rename 到目标；rename 是同名同盘的原子操作。
  Future<void> _writeAtomic(String path, List<int> bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
  }

  bool _segDone(String dir, int index) => _existingSegPath(dir, index) != null;

  /// 已完成分片的实际路径：明文 `seg_<n>.ts` 优先（兼容旧版下载即解密的产物），
  /// 其次密文 `seg_<n>.ts.enc`；都不存在（或为空文件）返回 null。
  String? _existingSegPath(String dir, int index) {
    for (final path in [_segPath(dir, index), _encSegPath(dir, index)]) {
      final f = File(path);
      if (f.existsSync() && f.lengthSync() > 0) return path;
    }
    return null;
  }

  String _segPath(String dir, int index) => p.join(dir, 'seg_$index.ts');

  String _encSegPath(String dir, int index) => p.join(dir, 'seg_$index.ts.enc');

  void _throwIfCancelled(CancelToken? cancelToken) {
    if (cancelToken != null && cancelToken.isCancelled) {
      throw cancelToken.cancelError ??
          DioException(
            requestOptions: RequestOptions(path: ''),
            type: DioExceptionType.cancel,
          );
    }
  }

  /// playlist 按 UTF-8 宽松解码并剥掉开头 BOM：逐字节转 char 会把 BOM 行当 URI
  /// 产生幽灵分片（挤歪 mediaSequence/隐式 IV），非 ASCII 分片名也会被二次编码成 404。
  String _decodeText(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  }
}
