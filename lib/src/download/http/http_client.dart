import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../../api/models/download_config.dart';

/// 请求命中 404/410 时抛出：CDN 直链过期的信号，触发上层调用 URL 刷新器。
class UrlExpiredException implements Exception {
  final int statusCode;
  final String url;

  const UrlExpiredException(this.statusCode, this.url);

  @override
  String toString() => 'UrlExpiredException($statusCode): url expired -> $url';
}

/// 非 404/410 的失败状态码（重试耗尽的 5xx，或其它 4xx）。
class HttpStatusException implements Exception {
  final int statusCode;
  final String url;

  const HttpStatusException(this.statusCode, this.url);

  @override
  String toString() => 'HttpStatusException($statusCode): $url';
}

/// HEAD 结果：断点续传所需的三要素，外加 content-type（供源类型识别用）。
class HeadInfo {
  final int? contentLength;
  final String? etag;
  final bool acceptRanges;
  final String? contentType;

  const HeadInfo({
    this.contentLength,
    this.etag,
    this.acceptRanges = false,
    this.contentType,
  });

  @override
  String toString() =>
      'HeadInfo(contentLength: $contentLength, etag: $etag, acceptRanges: $acceptRanges, contentType: $contentType)';
}

/// dio 的薄封装，供下载器使用。
///
/// 约定：
/// - 命中 [DownloadConfig.refreshStatusCodes]（默认 401/403/404/410）翻译成
/// [UrlExpiredException] 冒泡给上层（触发 URL 刷新），**不重试**。
/// - 连接/超时错误与 5xx 做有限次退避重试（[_maxTransientRetries]）。
/// - 其它 4xx 抛 [HttpStatusException]。
/// - 取消（CancelToken）直接冒泡，不重试。
class HttpClient {
  final DownloadConfig _config;
  final Dio _dio;

  int get _maxTransientRetries => _config.transientMaxRetries;

  /// 指数退避：1×/2×/4×… 504 等网关超时需要秒级窗口才可能恢复。
  Duration _backoffFor(int attempt) => _config.transientBackoff * (1 << attempt);

  HttpClient(DownloadConfig config, {Dio? dio})
      : _config = config,
        _dio = dio ?? _buildDio(config);

  static Dio _buildDio(DownloadConfig config) {
    return Dio(
      BaseOptions(
        connectTimeout: config.connectTimeout,
        receiveTimeout: config.receiveTimeout,
        headers: {'User-Agent': config.userAgent, ...config.headers},
        // 自行判定状态码，dio 不因非 2xx 抛异常，让 404/410 翻译更干净。
        validateStatus: (_) => true,
      ),
    );
  }

  DownloadConfig get config => _config;

  /// 仅供测试：校验内部 Dio 确实按配置构建（超时/UA 等）。
  @visibleForTesting
  Dio get dioForTesting => _dio;

  /// HEAD：取 content-length / ETag / accept-ranges。
  Future<HeadInfo> head(String url,
      {String? etag, CancelToken? cancelToken}) async {
    final resp = await _send<void>(
      () => _dio.head<void>(
        url,
        options: etag == null
            ? null
            : Options(headers: {'If-None-Match': etag}),
        cancelToken: cancelToken,
      ),
      url,
    );
    final h = resp.headers;
    final cl = int.tryParse(h.value('content-length') ?? '');
    final tag = h.value('etag');
    final ar = (h.value('accept-ranges') ?? '').toLowerCase().contains('bytes');
    final ct = h.value('content-type');
    return HeadInfo(
        contentLength: cl, etag: tag, acceptRanges: ar, contentType: ct);
  }

  /// 流式 GET，供大文件/分片边下边写。
  ///
  /// [rangeStart] 非空时带 `Range: bytes=<start>-`；[etag] 非空时带 `If-Range`
  /// 以保证续传的是同一份资源（资源变更时服务端会回 200 全量而非 206）。
  Future<Response<ResponseBody>> getStream(
    String url, {
    int? rangeStart,
    String? etag,
    CancelToken? cancelToken,
  }) {
    final headers = <String, dynamic>{};
    if (rangeStart != null) headers['Range'] = 'bytes=$rangeStart-';
    if (etag != null) headers['If-Range'] = etag;
    return _send<ResponseBody>(
      () => _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers.isEmpty ? null : headers,
        ),
        cancelToken: cancelToken,
      ),
      url,
    );
  }

  /// 整包 GET，返回字节（m3u8 播放列表、AES key、小文件）。
  Future<List<int>> getBytes(String url, {CancelToken? cancelToken}) async {
    final resp = await _send<List<int>>(
      () => _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancelToken,
      ),
      url,
    );
    return resp.data ?? const <int>[];
  }

  /// 区间 GET（`Range: bytes=<start>-<end>`，闭区间），供内容嗅探等只需开头
  /// 少量字节的场景。服务端忽略 Range 时会整包返回，调用方需自行截断。
  Future<List<int>> getBytesRange(
    String url,
    int start,
    int end, {
    CancelToken? cancelToken,
  }) async {
    final resp = await _send<List<int>>(
      () => _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=$start-$end'},
        ),
        cancelToken: cancelToken,
      ),
      url,
    );
    return resp.data ?? const <int>[];
  }

  void close() => _dio.close(force: true);

  /// 统一的发送 + 状态翻译 + 有限重试。
  Future<Response<T>> _send<T>(
    Future<Response<T>> Function() run,
    String url,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt <= _maxTransientRetries; attempt++) {
      try {
        final resp = await run();
        final code = resp.statusCode ?? 0;
        if (_config.refreshStatusCodes.contains(code)) {
          throw UrlExpiredException(code, url);
        }
        if (code >= 200 && code < 400) {
          return resp;
        }
        if (code >= 500) {
          lastError = HttpStatusException(code, url);
          if (attempt < _maxTransientRetries) {
            await Future<void>.delayed(_backoffFor(attempt));
            continue;
          }
        }
        // 其它 4xx（或重试耗尽的 5xx）：不可恢复，直接抛。
        throw HttpStatusException(code, url);
      } on UrlExpiredException {
        rethrow;
      } on HttpStatusException {
        rethrow;
      } on DioException catch (e) {
        // 注入的 dio 若用默认 validateStatus，非 2xx 会走这里。
        final code = e.response?.statusCode;
        if (code != null && _config.refreshStatusCodes.contains(code)) {
          throw UrlExpiredException(code, url);
        }
        if (_isTransient(e) && attempt < _maxTransientRetries) {
          lastError = e;
          await Future<void>.delayed(_backoffFor(attempt));
          continue;
        }
        // 有响应但非 2xx/3xx（重试耗尽的 5xx 或其它 4xx）：统一成 HttpStatusException，
        // 与 validateStatus 放行时的状态码分支行为一致。
        if (code != null) {
          throw HttpStatusException(code, url);
        }
        rethrow;
      }
    }
    throw lastError ?? StateError('unreachable retry state for $url');
  }

  static bool _isTransient(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        return code >= 500;
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        return false;
      default:
        return false;
    }
  }
}
