import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:video_cacher/src/api/models/download_config.dart';
import 'package:video_cacher/src/api/models/task_status.dart';
import 'package:video_cacher/src/download/http/http_client.dart';
import 'package:video_cacher/src/download/source_detector.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录调用次数、可为 HEAD/GET 返回不同状态与头，或直接抛异常。
class _RecordingAdapter implements HttpClientAdapter {
  final int statusCode;
  final List<int> body;
  final Map<String, List<String>> headers;

  int fetchCount = 0;
  final List<RequestOptions> requests = [];

  _RecordingAdapter(
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
    fetchCount++;
    requests.add(options);
    return ResponseBody.fromBytes(
      Uint8List.fromList(body),
      statusCode,
      headers: headers,
    );
  }

  @override
  void close({bool force = false}) {}
}

SourceDetector _detectorWith(_RecordingAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return SourceDetector(HttpClient(const DownloadConfig(), dio: dio));
}

void main() {
  test('.m3u8 URL（带 ?Expires 查询串）-> hls，且不发起网络请求', () async {
    final adapter = _RecordingAdapter(200);
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/live/index.m3u8?Expires=123&sig=x');
    expect(kind, SourceKind.hls);
    expect(adapter.fetchCount, 0);
  });

  test('.mp4 URL（带查询串）-> mp4，且不发起网络请求', () async {
    final adapter = _RecordingAdapter(200);
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/v/movie.mp4?token=abc');
    expect(kind, SourceKind.mp4);
    expect(adapter.fetchCount, 0);
  });

  test('无扩展名 + HEAD Content-Type application/vnd.apple.mpegurl -> hls',
      () async {
    final adapter = _RecordingAdapter(200, headers: {
      'content-type': ['application/vnd.apple.mpegurl'],
    });
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/stream/playlist');
    expect(kind, SourceKind.hls);
  });

  test('无扩展名 + HEAD Content-Type video/mp4（带 charset）-> mp4', () async {
    final adapter = _RecordingAdapter(200, headers: {
      'content-type': ['video/mp4; charset=binary'],
    });
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/stream/asset');
    expect(kind, SourceKind.mp4);
  });

  test('无扩展名 + Content-Type 缺失/歧义 + 内容嗅探 #EXTM3U -> hls', () async {
    final adapter = _RecordingAdapter(
      200,
      headers: const {},
      body: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
    );
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/stream/ambiguous');
    expect(kind, SourceKind.hls);
  });

  test('无扩展名 + HEAD 失败 + 内容非 #EXTM3U -> 默认 mp4（不抛异常）', () async {
    // HEAD 与 GET 共用同一 adapter：返回 500 让 head() 抛错，getBytes 拿到非 m3u8 内容。
    final adapter = _RecordingAdapter(500, body: <int>[0, 0, 0, 24]);
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/stream/unknown');
    expect(kind, SourceKind.mp4);
  });

  test('嗅探是区间请求（Range: bytes=0-63），#EXTM3U 仍识别为 hls', () async {
    final adapter = _RecordingAdapter(
      206,
      body: utf8.encode('#EXTM3U\n#EXT-X-VERSION:3\n'),
    );
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/stream/ambiguous');
    expect(kind, SourceKind.hls);

    // 嗅探绝不能整包 GET 视频：GET 必须带开头 64 字节的 Range。
    final get = adapter.requests.firstWhere((o) => o.method == 'GET');
    expect(get.headers['Range'], 'bytes=0-63');
  });

  test('嗅探区间请求：非 m3u8 内容 -> mp4，同样只拉开头字节', () async {
    final adapter = _RecordingAdapter(206, body: <int>[0, 0, 0, 24]);
    final d = _detectorWith(adapter);
    final kind = await d.detect('https://cdn/stream/binary');
    expect(kind, SourceKind.mp4);

    final get = adapter.requests.firstWhere((o) => o.method == 'GET');
    expect(get.headers['Range'], 'bytes=0-63');
  });
}
