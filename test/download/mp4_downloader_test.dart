import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:video_cacher/src/api/models/download_config.dart';
import 'package:video_cacher/src/download/http/http_client.dart';
import 'package:video_cacher/src/download/http/url_refresher.dart';
import 'package:video_cacher/src/download/mp4/mp4_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

/// 路由式假适配器：按 (method, url) 交给 handler 决定返回什么。
class _FakeAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;

  _FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

/// 大小写不敏感取请求头。
String? _hdr(RequestOptions o, String name) {
  for (final e in o.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value?.toString();
  }
  return null;
}

ResponseBody _bytesBody(
  int status,
  List<int> body, {
  Map<String, List<String>> headers = const {},
}) =>
    ResponseBody.fromBytes(Uint8List.fromList(body), status, headers: headers);

Mp4Downloader _downloader(
  _FakeAdapter adapter, {
  RefreshUrlCallback? refresh,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  final http = HttpClient(const DownloadConfig(), dio: dio);
  final refresher = UrlRefresher(callback: refresh, backoff: Duration.zero);
  return Mp4Downloader(http: http, refresher: refresher);
}

List<int> _range(int start, int end) =>
    List<int>.generate(end - start, (i) => (start + i) % 256);

void main() {
  late Directory dir;
  late String dest;
  late String part;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mp4dl_');
    dest = '${dir.path}/out.mp4';
    part = '$dest.part';
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('1. 全新下载：无 .part，服务端 200，字节完整落盘且 .part 消失', () async {
    final full = _range(0, 100);
    final adapter = _FakeAdapter((o) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      return _bytesBody(200, full);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't1',
      url: 'https://cdn/a.mp4',
      destPath: dest,
    );

    expect(File(dest).readAsBytesSync(), full);
    expect(r.totalBytes, 100);
    expect(File(part).existsSync(), isFalse);
  });

  test('2. 206 续传：预置前 K 字节，Range 请求返回 206 余下字节，拼接正确', () async {
    final full = _range(0, 100);
    const k = 40;
    File(part).writeAsBytesSync(full.sublist(0, k));

    String? rangeHdr;
    final adapter = _FakeAdapter((o) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      rangeHdr = _hdr(o, 'Range');
      return _bytesBody(206, full.sublist(k), headers: {
        'content-length': ['${100 - k}'],
        'content-range': ['bytes $k-99/100'],
      });
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't2',
      url: 'https://cdn/a.mp4',
      destPath: dest,
      knownEtag: '"v1"',
    );

    expect(rangeHdr, 'bytes=$k-');
    expect(File(dest).readAsBytesSync(), full);
    expect(r.totalBytes, 100);
  });

  test('3. ETag 变化：.part 存在但 HEAD etag != knownEtag，从 0 重下', () async {
    final full = _range(0, 100);
    File(part).writeAsBytesSync(List<int>.filled(40, 0xEE)); // 旧脏数据

    final adapter = _FakeAdapter((o) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v2"'], // 变了
          'accept-ranges': ['bytes'],
        });
      }
      // offset=0 -> 不带 Range，返回全量 200
      return _bytesBody(200, full);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't3',
      url: 'https://cdn/a.mp4',
      destPath: dest,
      knownEtag: '"v1"',
    );

    expect(File(dest).readAsBytesSync(), full);
    expect(r.totalBytes, 100);
  });

  test('4. 服务端忽略 Range：带 Range 却回 200 全量，丢弃 .part 从 0 写', () async {
    final full = _range(0, 100);
    const k = 40;
    File(part).writeAsBytesSync(full.sublist(0, k));

    final adapter = _FakeAdapter((o) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      // 尽管收到 Range，仍回 200 全量
      return _bytesBody(200, full, headers: {
        'content-length': ['100'],
      });
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't4',
      url: 'https://cdn/a.mp4',
      destPath: dest,
      knownEtag: '"v1"',
    );

    expect(File(dest).readAsBytesSync(), full);
    expect(r.totalBytes, 100);
  });

  test('5. 首个 GET 404 -> 刷新换 URL -> 成功，finalUrl 为新地址', () async {
    final full = _range(0, 60);
    const newUrl = 'https://cdn/refreshed.mp4';
    final adapter = _FakeAdapter((o) async {
      final url = o.uri.toString();
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['60'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      // 旧 URL 的 GET 过期，新 URL 的 GET 成功。
      if (url != newUrl) return _bytesBody(404, const []);
      return _bytesBody(200, full);
    });
    final dl = _downloader(adapter, refresh: (_) async => newUrl);

    final r = await dl.download(
      taskId: 't5',
      url: 'https://cdn/old.mp4',
      destPath: dest,
    );

    expect(File(dest).readAsBytesSync(), full);
    expect(r.finalUrl, newUrl);
  });

  test('6. 续传时已完整：.part == 全长，Range GET 回 416，视为完成', () async {
    final full = _range(0, 100);
    File(part).writeAsBytesSync(full); // 已完整

    final adapter = _FakeAdapter((o) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      // 请求 Range: bytes=100- 超出范围
      return _bytesBody(416, const []);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't6',
      url: 'https://cdn/a.mp4',
      destPath: dest,
      knownEtag: '"v1"',
    );

    expect(File(dest).readAsBytesSync(), full);
    expect(r.totalBytes, 100);
    expect(File(part).existsSync(), isFalse);
  });

  test('7. 流中途取消：抛出取消异常，.part 保留已下字节', () async {
    final first = _range(0, 30);
    final adapter = _FakeAdapter((o) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      // 先吐一段，再以取消异常中断。
      final stream = Stream<Uint8List>.fromIterable([
        Uint8List.fromList(first),
      ]).asyncExpand((chunk) async* {
        yield chunk;
        throw DioException(requestOptions: o, type: DioExceptionType.cancel);
      });
      return ResponseBody(stream, 200, headers: {
        'content-length': ['100'],
      });
    });
    final dl = _downloader(adapter);

    await expectLater(
      dl.download(
        taskId: 't7',
        url: 'https://cdn/a.mp4',
        destPath: dest,
        cancelToken: CancelToken(),
      ),
      throwsA(isA<DioException>()
          .having((e) => e.type, 'type', DioExceptionType.cancel)),
    );

    expect(File(dest).existsSync(), isFalse);
    expect(File(part).existsSync(), isTrue);
    expect(File(part).readAsBytesSync(), first);
  });
}
