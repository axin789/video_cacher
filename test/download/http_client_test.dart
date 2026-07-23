import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:video_cacher/src/api/models/download_config.dart';
import 'package:video_cacher/src/download/http/http_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定返回一个状态码/字节/头的假适配器，无需真实网络。
class _FakeAdapter implements HttpClientAdapter {
  final int statusCode;
  final List<int> body;
  final Map<String, List<String>> headers;

  _FakeAdapter(
    this.statusCode, {
    this.body = const <int>[],
    this.headers = const <String, List<String>>{},
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      Uint8List.fromList(body),
      statusCode,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 记录请求头/调用次数，可选择抛出指定类型异常，用于头部断言与取消/重试断言。
class _RecordingAdapter implements HttpClientAdapter {
  final int statusCode;
  final List<int> body;
  final DioExceptionType? throwType;

  int fetchCount = 0;
  RequestOptions? lastOptions;

  _RecordingAdapter(
    this.statusCode, {
    this.body = const <int>[],
    this.throwType,
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    lastOptions = options;
    final type = throwType;
    if (type != null) {
      throw DioException(requestOptions: options, type: type);
    }
    return ResponseBody.fromBytes(Uint8List.fromList(body), statusCode);
  }

  @override
  void close({bool force = false}) {}
}

/// 按请求逐次决定响应的假适配器（用于多次重试的场景）。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.handler);

  final ResponseBody Function(RequestOptions o) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

/// 大小写不敏感地取请求头。
String? _hdr(RequestOptions o, String name) {
  for (final e in o.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value?.toString();
  }
  return null;
}

HttpClient _clientWith(
  int status, {
  List<int> body = const <int>[],
  Map<String, List<String>> headers = const <String, List<String>>{},
  bool permissive = false,
}) {
  final dio = Dio();
  if (permissive) dio.options.validateStatus = (_) => true;
  dio.httpClientAdapter =
      _FakeAdapter(status, body: body, headers: headers);
  return HttpClient(const DownloadConfig(), dio: dio);
}

void main() {
  group('HttpClient refreshStatusCodes -> UrlExpiredException', () {
    test('403 默认视为过期（部分 CDN 用 403 表示 token 过期）', () {
      final c = _clientWith(403);
      expect(
        c.getBytes('https://cdn/x.m3u8'),
        throwsA(isA<UrlExpiredException>()
            .having((e) => e.statusCode, 'statusCode', 403)),
      );
    });

    test('自定义集合可排除 403 -> 走 HttpStatusException', () {
      final dio = Dio()..httpClientAdapter = _FakeAdapter(403);
      final c = HttpClient(
        const DownloadConfig(refreshStatusCodes: {404, 410}),
        dio: dio,
      );
      expect(
        c.getBytes('https://cdn/x.m3u8'),
        throwsA(isA<HttpStatusException>()),
      );
    });
  });

  group('HttpClient 404/410 -> UrlExpiredException', () {
    test('getBytes 404（默认 validateStatus，走 DioException 分支）', () {
      final c = _clientWith(404);
      expect(
        c.getBytes('https://cdn/x.m3u8'),
        throwsA(
          isA<UrlExpiredException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having((e) => e.url, 'url', 'https://cdn/x.m3u8'),
        ),
      );
    });

    test('getBytes 410', () {
      final c = _clientWith(410);
      expect(
        c.getBytes('https://cdn/x.key'),
        throwsA(isA<UrlExpiredException>()
            .having((e) => e.statusCode, 'statusCode', 410)),
      );
    });

    test('head 404', () {
      final c = _clientWith(404);
      expect(c.head('https://cdn/v.mp4'), throwsA(isA<UrlExpiredException>()));
    });

    test('getStream 404', () {
      final c = _clientWith(404);
      expect(
        c.getStream('https://cdn/seg0.ts', rangeStart: 0),
        throwsA(isA<UrlExpiredException>()),
      );
    });

    test('permissive validateStatus 下 404 同样翻译（走状态码分支）', () {
      final c = _clientWith(404, permissive: true);
      expect(
        c.getBytes('https://cdn/x.m3u8'),
        throwsA(isA<UrlExpiredException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });
  });

  group('HttpClient 正常响应', () {
    test('getBytes 200 返回字节', () async {
      final c = _clientWith(200, body: <int>[1, 2, 3, 4]);
      expect(await c.getBytes('https://cdn/x.m3u8'), <int>[1, 2, 3, 4]);
    });

    test('head 200 解析 content-length/etag/accept-ranges', () async {
      final c = _clientWith(200, headers: {
        'content-length': ['2048'],
        'etag': ['"abc123"'],
        'accept-ranges': ['bytes'],
      });
      final info = await c.head('https://cdn/v.mp4');
      expect(info.contentLength, 2048);
      expect(info.etag, '"abc123"');
      expect(info.acceptRanges, isTrue);
    });
  });

  group('HttpClient 5xx 瞬时故障重试', () {
    test('504 先失败后成功：按 transientMaxRetries 重试，最终返回', () async {
      var calls = 0;
      final dio = Dio()
        ..httpClientAdapter = _RoutingAdapter((o) {
          calls++;
          return ResponseBody.fromBytes(
            Uint8List.fromList(calls <= 2 ? const <int>[] : const [1, 2, 3]),
            calls <= 2 ? 504 : 200,
          );
        });
      final c = HttpClient(
        const DownloadConfig(
          transientMaxRetries: 3,
          transientBackoff: Duration(milliseconds: 1),
        ),
        dio: dio,
      );
      final bytes = await c.getBytes('https://cdn/seg.ts');
      expect(bytes, [1, 2, 3]);
      expect(calls, 3, reason: '两次 504 后第三次成功');
    });

    test('504 持续不恢复：重试耗尽后抛 HttpStatusException', () async {
      var calls = 0;
      final dio = Dio()
        ..httpClientAdapter = _RoutingAdapter((o) {
          calls++;
          return ResponseBody.fromBytes(Uint8List(0), 504);
        });
      final c = HttpClient(
        const DownloadConfig(
          transientMaxRetries: 2,
          transientBackoff: Duration(milliseconds: 1),
        ),
        dio: dio,
      );
      await expectLater(
        c.getBytes('https://cdn/seg.ts'),
        throwsA(isA<HttpStatusException>()
            .having((e) => e.statusCode, 'statusCode', 504)),
      );
      expect(calls, 3, reason: '首次 + 2 次重试');
    });
  });

  group('HttpClient 其它状态码', () {
    // 403 已默认归入过期刷新集合，这里用 400 验证「其它 4xx 不刷新不重试」。
    test('400 抛 HttpStatusException（非 UrlExpired，不重试）', () {
      final c = _clientWith(400);
      expect(
        c.getBytes('https://cdn/x.m3u8'),
        throwsA(isA<HttpStatusException>()),
      );
    });
  });

  group('HttpClient getStream Range/If-Range 头与 206/200', () {
    test('rangeStart 非空发出 Range: bytes=100-；null 时不发 Range', () async {
      final withRange = _RecordingAdapter(206);
      final dio1 = Dio()..httpClientAdapter = withRange;
      final c1 = HttpClient(const DownloadConfig(), dio: dio1);
      await c1.getStream('https://cdn/v.mp4', rangeStart: 100);
      expect(_hdr(withRange.lastOptions!, 'Range'), 'bytes=100-');

      final noRange = _RecordingAdapter(200);
      final dio2 = Dio()..httpClientAdapter = noRange;
      final c2 = HttpClient(const DownloadConfig(), dio: dio2);
      await c2.getStream('https://cdn/v.mp4');
      expect(_hdr(noRange.lastOptions!, 'Range'), isNull);
    });

    test('传 etag 发出 If-Range；不传时不发 If-Range', () async {
      final withEtag = _RecordingAdapter(206);
      final dio1 = Dio()..httpClientAdapter = withEtag;
      final c1 = HttpClient(const DownloadConfig(), dio: dio1);
      await c1.getStream('https://cdn/v.mp4', rangeStart: 100, etag: 'abc');
      expect(_hdr(withEtag.lastOptions!, 'If-Range'), 'abc');

      final noEtag = _RecordingAdapter(206);
      final dio2 = Dio()..httpClientAdapter = noEtag;
      final c2 = HttpClient(const DownloadConfig(), dio: dio2);
      await c2.getStream('https://cdn/v.mp4', rangeStart: 100);
      expect(_hdr(noEtag.lastOptions!, 'If-Range'), isNull);
    });

    test('206 Partial Content 视为成功，statusCode == 206', () async {
      final c = _clientWith(206);
      final resp = await c.getStream('https://cdn/v.mp4', rangeStart: 100);
      expect(resp.statusCode, 206);
    });

    test('服务器忽略 Range 返回 200 也成功，statusCode == 200', () async {
      final c = _clientWith(200);
      final resp = await c.getStream('https://cdn/v.mp4', rangeStart: 100);
      expect(resp.statusCode, 200);
    });
  });

  group('HttpClient 未注入 dio 时按配置自建', () {
    test('connectTimeout/receiveTimeout/User-Agent 均来自 DownloadConfig', () {
      const config = DownloadConfig();
      final c = HttpClient(config);
      final options = c.dioForTesting.options;
      expect(options.connectTimeout, config.connectTimeout);
      expect(options.receiveTimeout, config.receiveTimeout);
      expect(options.headers['User-Agent'], config.userAgent);
    });

    test('自定义 headers 合并进全部请求，同名覆盖 User-Agent', () {
      const config = DownloadConfig(
        headers: {'referer': 'https://app.example.com', 'User-Agent': 'ua2'},
      );
      final c = HttpClient(config);
      final options = c.dioForTesting.options;
      expect(options.headers['referer'], 'https://app.example.com');
      expect(options.headers['User-Agent'], 'ua2');
    });
  });

  group('HttpClient CancelToken 取消立即传播', () {
    test('已取消的 CancelToken -> 抛取消异常，不重试', () async {
      final adapter = _RecordingAdapter(200, body: <int>[1]);
      final dio = Dio()..httpClientAdapter = adapter;
      final c = HttpClient(const DownloadConfig(), dio: dio);
      final token = CancelToken()..cancel('user paused');

      await expectLater(
        c.getBytes('https://cdn/x.m3u8', cancelToken: token),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      // dio 在取消状态下短路，不应触达 adapter，更不会重试。
      expect(adapter.fetchCount, 0);
    });

    test('请求中途抛 cancel -> 不被瞬时重试（adapter 只调一次）', () async {
      final adapter =
          _RecordingAdapter(200, throwType: DioExceptionType.cancel);
      final dio = Dio()..httpClientAdapter = adapter;
      final c = HttpClient(const DownloadConfig(), dio: dio);

      await expectLater(
        c.getBytes('https://cdn/x.m3u8'),
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
      expect(adapter.fetchCount, 1);
    });
  });
}
