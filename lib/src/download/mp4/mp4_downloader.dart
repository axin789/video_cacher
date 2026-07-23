import 'dart:io';

import 'package:dio/dio.dart';

import '../../log.dart';
import '../http/http_client.dart';
import '../http/url_refresher.dart';

void _noop(int downloaded, int total) {}

/// mp4 下载嗅探到响应体其实是 m3u8 播放列表（源类型误判）时抛出；
/// 引擎捕获后把任务纠正为 HLS 重跑，而非永久失败。
class PlaylistContentException implements Exception {
  final String message;

  const PlaylistContentException(this.message);

  @override
  String toString() => 'PlaylistContentException: $message';
}

/// MP4 下载结果：把可能被刷新过的最终 URL 与 ETag 回传给引擎持久化。
class Mp4DownloadResult {
  final String finalUrl;
  final String? etag;
  final int totalBytes;
  final String mp4Path;

  const Mp4DownloadResult({
    required this.finalUrl,
    required this.etag,
    required this.totalBytes,
    required this.mp4Path,
  });
}

/// MP4 直链下载器：HEAD 探测 → Range 断点续传 → 流式写 `.part` → 完成 rename。
///
/// 稳定性核心：
/// - 续传前用 ETag 校验资源未变（变了就从 0 重下，避免拼接出损坏文件）。
/// - 404/410（直链过期）经刷新器换新 URL，**从已下字节处续传**，有次数上限防死循环。
/// - 服务端忽略 Range 回 200 全量时，丢弃旧 `.part` 从 0 写。
/// - 已完整（`.part` >= 文件大小）时 Range 请求回 416，视为完成直接 rename。
class Mp4Downloader {
  final HttpClient _http;
  final UrlRefresher _refresher;

  /// 单次 download 调用内最多追随几次 URL 刷新，超过则以底层错误放弃。
  static const int _maxUrlRefreshes = 3;

  /// 流消费中途瞬断（超时/连接错/5xx）的最大续拉次数与退避。
  static const int _maxStreamRetries = 2;
  static const Duration _streamRetryBackoff = Duration(milliseconds: 500);

  Mp4Downloader({required HttpClient http, required UrlRefresher refresher})
      : _http = http,
        _refresher = refresher;

  Future<Mp4DownloadResult> download({
    required String taskId,
    required String url,
    required String destPath,
    String? partPath,
    String? knownEtag,
    void Function(String? etag)? onEtag,
    void Function(int downloaded, int total) onProgress = _noop,
    CancelToken? cancelToken,
  }) async {
    final part = File(partPath ?? '$destPath.part');
    var currentUrl = url;
    var refreshes = 0;

    while (true) {
      try {
        final r = await _attempt(
          taskId: taskId,
          url: currentUrl,
          dest: File(destPath),
          part: part,
          knownEtag: knownEtag,
          onEtag: onEtag,
          onProgress: onProgress,
          cancelToken: cancelToken,
        );
        VideoCacherLog.d(
            'mp4', '[$taskId] 完成: ${r.mp4Path} (${r.totalBytes} bytes)');
        return r;
      } on UrlExpiredException catch (e) {
        // 直链过期：换新 URL 后重试，保留 `.part` 从已下字节处续传。
        if (refreshes >= _maxUrlRefreshes) {
          VideoCacherLog.d(
              'mp4', '[$taskId] 刷新次数超上限($_maxUrlRefreshes)，放弃');
          rethrow;
        }
        refreshes++;
        VideoCacherLog.d(
            'mp4',
            '[$taskId] ${e.statusCode} 过期 -> '
            '刷新 URL（第 $refreshes/$_maxUrlRefreshes 次）');
        currentUrl = await _refresher.refresh(taskId);
      }
    }
  }

  Future<Mp4DownloadResult> _attempt({
    required String taskId,
    required String url,
    required File dest,
    required File part,
    required String? knownEtag,
    required void Function(String? etag)? onEtag,
    required void Function(int downloaded, int total) onProgress,
    required CancelToken? cancelToken,
  }) async {
    final headInfo = await _http.head(url, cancelToken: cancelToken);
    final headEtag = headInfo.etag;
    final totalLen = headInfo.contentLength;
    // HEAD 一返回就上报 etag，让引擎尽早持久化——中途 kill/暂停后仍能校验内容未变。
    onEtag?.call(headEtag);

    // 计算续传偏移：`.part` 有字节 + 服务端支持 Range + ETag 未变 → 续传，否则从 0。
    var offset = 0;
    final existing = part.existsSync() ? part.lengthSync() : 0;
    final etagMatches =
        knownEtag == null || headEtag == null || knownEtag == headEtag;
    if (existing > 0 && headInfo.acceptRanges && etagMatches) {
      offset = existing;
    } else if (existing > 0 && !etagMatches) {
      // 内容已变更：旧 `.part` 属于过期版本，删掉从 0 重下。
      part.deleteSync();
    }
    VideoCacherLog.d(
        'mp4',
        '[$taskId] HEAD len=$totalLen etag=$headEtag '
        'ranges=${headInfo.acceptRanges} 续传偏移=$offset');

    // If-Range 必须带「旧」etag 才有防内容变更的意义（带刚 HEAD 到的新 etag 是
    // 恒真校验）；弱 etag（W/）按 RFC 7233 不可用于 If-Range，退化为裸 Range 续传。
    final ifRange =
        (knownEtag != null && !knownEtag.startsWith('W/')) ? knownEtag : null;

    Response<ResponseBody>? resp;
    // 416 异常态（总长未知/与 HEAD 不一致）只从 0 重试一次，防死循环。
    var retriedAfter416 = false;
    while (resp == null) {
      try {
        resp = await _http.getStream(
          url,
          rangeStart: offset > 0 ? offset : null,
          etag: offset > 0 ? ifRange : null,
          cancelToken: cancelToken,
        );
      } on HttpStatusException catch (e) {
        if (e.statusCode != 416 || offset == 0) rethrow;
        // 416 且 `.part` 已 >= 文件大小：说明其实已下完，视为完成。
        if (totalLen != null && offset >= totalLen) {
          return _finish(part, dest, url, headEtag, totalLen, onProgress);
        }
        // 总长未知（或 offset < totalLen 却仍 416）：`.part` 不可信，
        // 删掉从 0 重试一次；否则每次 resume 都撞 416 永久失败。
        if (retriedAfter416) rethrow;
        retriedAfter416 = true;
        if (part.existsSync()) part.deleteSync();
        offset = 0;
      }
    }

    final status = resp.statusCode ?? 0;
    // 请求了 Range 但服务端回 200（忽略 Range / If-Range 不匹配）→ 全量，从 0 覆盖写。
    final resuming = offset > 0 && status == 206;
    final writeOffset = resuming ? offset : 0;

    // totalBytes：206 优先用 Content-Range 的总长，否则 HEAD content-length；
    // 200 时 body 即全量，用响应 content-length，回退 HEAD。
    var total = _resolveTotal(resp, resuming, writeOffset, totalLen);

    var written = writeOffset;
    var aborted = false;
    // 流消费中途瞬断：按已写字节 Range 续拉同一 URL，有限次重试；
    // 取消/URL 过期不在此兜，保持原有语义冒泡。
    var streamRetries = 0;
    try {
      var stream = resp.data?.stream;
      while (stream != null) {
        final sink = part.openSync(
          mode: written > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
        );
        // 仅从 0 起写时嗅探首个分块是否 m3u8 文本，续写跳过。
        var sniff = written == 0;
        try {
          await for (final chunk in stream) {
            if (sniff) {
              sniff = false;
              if (_looksLikeM3u8(chunk)) {
                // 播放列表文本被当 mp4 下（源类型误判）：中止并清 .part，不落成片。
                aborted = true;
                throw const PlaylistContentException(
                    'URL 内容是 m3u8 播放列表而非视频（源类型误判）');
              }
            }
            sink.writeFromSync(chunk);
            written += chunk.length;
            onProgress(written, total > 0 ? total : written);
          }
          stream = null; // 消费完毕
        } on DioException catch (e) {
          if (!_isTransientMidStream(e) || streamRetries >= _maxStreamRetries) {
            rethrow;
          }
          streamRetries++;
          VideoCacherLog.d(
              'mp4',
              '[$taskId] 流中断(${e.type.name})，'
              '第 $streamRetries/$_maxStreamRetries 次从 $written 续拉');
          await Future<void>.delayed(_streamRetryBackoff);
          final retry = await _http.getStream(
            url,
            rangeStart: written > 0 ? written : null,
            etag: written > 0 ? ifRange : null,
            cancelToken: cancelToken,
          );
          final retryResuming = written > 0 && retry.statusCode == 206;
          // 续拉被回 200 全量（服务端忽略 Range）：丢弃已写从 0 重来。
          if (!retryResuming) written = 0;
          total = _resolveTotal(retry, retryResuming, written, totalLen);
          stream = retry.data?.stream;
        } finally {
          sink.closeSync();
        }
      }
    } finally {
      if (aborted && part.existsSync()) part.deleteSync();
    }

    final resolvedTotal = total > 0 ? total : written;
    return _finish(part, dest, url, headEtag, resolvedTotal, onProgress);
  }

  /// 流消费中可安全续拉的瞬时错误：连接/超时类，或 5xx。取消与 4xx 不算。
  static bool _isTransientMidStream(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        return (e.response?.statusCode ?? 0) >= 500;
      default:
        return false;
    }
  }

  /// rename `.part` → dest，回调一次终态进度，返回结果。
  Mp4DownloadResult _finish(
    File part,
    File dest,
    String url,
    String? etag,
    int total,
    void Function(int downloaded, int total) onProgress,
  ) {
    part.renameSync(dest.path);
    onProgress(total, total);
    return Mp4DownloadResult(
      finalUrl: url,
      etag: etag,
      totalBytes: total,
      mp4Path: dest.path,
    );
  }

  /// 解析总字节数：优先 206 的 Content-Range 总长，其次响应 content-length，回退 HEAD。
  int _resolveTotal(
    Response<ResponseBody> resp,
    bool resuming,
    int writeOffset,
    int? headTotal,
  ) {
    final headers = resp.headers;
    final cr = headers.value('content-range');
    if (cr != null) {
      final slash = cr.lastIndexOf('/');
      if (slash >= 0) {
        final t = int.tryParse(cr.substring(slash + 1).trim());
        if (t != null && t > 0) return t;
      }
    }
    final cl = int.tryParse(headers.value('content-length') ?? '');
    if (cl != null) {
      // 206 部分长度需加上已写偏移才是文件总长。
      return resuming ? writeOffset + cl : cl;
    }
    return headTotal ?? 0;
  }

  /// 首个分块是否为 m3u8 播放列表文本：跳过可选 UTF-8 BOM 与少量空白后以
  /// #EXTM3U 开头。最多看前 16 字节左右，代价可忽略。
  static bool _looksLikeM3u8(List<int> chunk) {
    var i = 0;
    if (chunk.length >= 3 &&
        chunk[0] == 0xEF &&
        chunk[1] == 0xBB &&
        chunk[2] == 0xBF) {
      i = 3;
    }
    while (i < chunk.length &&
        i < 16 &&
        (chunk[i] == 0x20 ||
            chunk[i] == 0x09 ||
            chunk[i] == 0x0D ||
            chunk[i] == 0x0A)) {
      i++;
    }
    const sig = '#EXTM3U';
    if (chunk.length - i < sig.length) return false;
    for (var j = 0; j < sig.length; j++) {
      if (chunk[i + j] != sig.codeUnitAt(j)) return false;
    }
    return true;
  }
}
