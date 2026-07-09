import 'dart:convert';

import 'package:dio/dio.dart';

import '../api/models/task_status.dart';
import 'http/http_client.dart';

/// 判定给定 URL 是 mp4 直链还是 m3u8(HLS)。
///
/// 判定顺序（便宜 → 昂贵，越早确定越好）：
/// 1. URL 路径扩展名（忽略 query/fragment）；
/// 2. HEAD 的 Content-Type；
/// 3. 拉取开头字节嗅探 `#EXTM3U`。
///
/// 全部不确定时默认 [SourceKind.mp4]。除真正的取消（CancelToken）外，
/// 识别过程中的任何失败都不抛异常，只向下一步回退。
class SourceDetector {
  final HttpClient _http;

  SourceDetector(this._http);

  Future<SourceKind> detect(String url, {CancelToken? cancelToken}) async {
    final byExt = _byExtension(url);
    if (byExt != null) return byExt;

    final byType = await _byContentType(url, cancelToken);
    if (byType != null) return byType;

    return _bySniff(url, cancelToken);
  }

  /// 1. 扩展名判定。
  SourceKind? _byExtension(String url) {
    final path = _stripQuery(url).toLowerCase();
    if (path.endsWith('.m3u8')) return SourceKind.hls;
    if (path.endsWith('.mp4') ||
        path.endsWith('.m4v') ||
        path.endsWith('.mov')) {
      return SourceKind.mp4;
    }
    return null;
  }

  /// 2. Content-Type 判定（HEAD）。失败/缺失/歧义一律回退（返回 null）。
  Future<SourceKind?> _byContentType(String url, CancelToken? token) async {
    try {
      final ct = (await _http.head(url, cancelToken: token)).contentType;
      if (ct == null) return null;
      final v = ct.toLowerCase();
      // application/vnd.apple.mpegurl、application/x-mpegurl、audio/mpegurl 都含 "mpegurl"。
      if (v.contains('mpegurl')) return SourceKind.hls;
      if (v.contains('video/mp4') || v.contains('video/quicktime')) {
        return SourceKind.mp4;
      }
      return null;
    } catch (e) {
      if (_isCancel(e)) rethrow;
      return null;
    }
  }

  /// 3. 内容嗅探：开头是否为 `#EXTM3U`。否则默认 mp4。
  Future<SourceKind> _bySniff(String url, CancelToken? token) async {
    try {
      final bytes = await _http.getBytes(url, cancelToken: token);
      final head = utf8
          .decode(bytes.length > 64 ? bytes.sublist(0, 64) : bytes,
              allowMalformed: true)
          .trimLeft();
      if (head.startsWith('#EXTM3U')) return SourceKind.hls;
    } catch (e) {
      if (_isCancel(e)) rethrow;
    }
    return SourceKind.mp4;
  }

  static String _stripQuery(String url) {
    var s = url;
    final q = s.indexOf('?');
    if (q >= 0) s = s.substring(0, q);
    final h = s.indexOf('#');
    if (h >= 0) s = s.substring(0, h);
    return s;
  }

  static bool _isCancel(Object e) =>
      e is DioException && e.type == DioExceptionType.cancel;
}
