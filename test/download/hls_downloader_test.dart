import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:video_cacher/src/api/models/download_config.dart';
import 'package:video_cacher/src/download/http/http_client.dart';
import 'package:video_cacher/src/download/http/url_refresher.dart';
import 'package:video_cacher/src/download/hls/aes_decryptor.dart';
import 'package:video_cacher/src/download/hls/hls_downloader.dart';
import 'package:video_cacher/src/download/hls/m3u8_parser.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

/// 路由式假适配器：按 url 交给 handler 决定返回什么，并记录被请求过的 url。
class _FakeAdapter implements HttpClientAdapter {
  final ResponseBody Function(String url) handler;
  final List<String> requested = [];

  _FakeAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requested.add(url);
    return handler(url);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _body(int status, List<int> bytes) =>
    ResponseBody.fromBytes(Uint8List.fromList(bytes), status);

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

Uint8List _encrypt(List<int> plain, List<int> key, List<int> iv) {
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  )..init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
        null,
      ),
    );
  return cipher.process(Uint8List.fromList(plain));
}

HlsDownloader _downloader(_FakeAdapter adapter, {RefreshUrlCallback? refresh}) {
  final dio = Dio()..httpClientAdapter = adapter;
  final http = HttpClient(const DownloadConfig(), dio: dio);
  final refresher = UrlRefresher(callback: refresh, backoff: Duration.zero);
  return HlsDownloader(http: http, refresher: refresher);
}

void main() {
  final key = _hex('00112233445566778899aabbccddeeff');
  const ivHex = '000102030405060708090a0b0c0d0e0f';
  final iv = _hex(ivHex);

  final p0 = Uint8List.fromList('segment-zero-payload'.codeUnits);
  final p1 = Uint8List.fromList('segment-one-payload!!'.codeUnits);
  final p2 = Uint8List.fromList('segment-two-final-pay'.codeUnits);

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('hlsdl_');
  });
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String encMediaPlaylist(String segPrefix) => '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x$ivHex
#EXTINF:4.0,
${segPrefix}seg0.ts
#EXTINF:4.0,
${segPrefix}seg1.ts
#EXTINF:4.0,
${segPrefix}seg2.ts
#EXT-X-ENDLIST
''';

  test('1. 加密 happy path：3 片解密正确、有序、进度到 3/3', () async {
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) {
        return _body(200, encMediaPlaylist('').codeUnits);
      }
      if (url.endsWith('/key.bin')) return _body(200, key);
      if (url.endsWith('/seg0.ts')) return _body(200, _encrypt(p0, key, iv));
      if (url.endsWith('/seg1.ts')) return _body(200, _encrypt(p1, key, iv));
      if (url.endsWith('/seg2.ts')) return _body(200, _encrypt(p2, key, iv));
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    final progress = <List<int>>[];
    final r = await dl.download(
      taskId: 't1',
      entryUrl: 'https://cdn/hls/index.m3u8',
      dir: dir.path,
      onProgress: (d, t) => progress.add([d, t]),
    );

    expect(r.segmentFiles.length, 3);
    expect(r.finalEntryUrl, 'https://cdn/hls/index.m3u8');
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
    expect(File('${dir.path}/seg_2.ts').readAsBytesSync(), p2);
    expect(r.segmentFiles, [
      '${dir.path}/seg_0.ts',
      '${dir.path}/seg_1.ts',
      '${dir.path}/seg_2.ts',
    ]);
    expect(progress.last, [3, 3]);
  });

  test('2. 续传：预置 seg_1.ts → 跳过 seg1 下载，仍返回全部 3 片', () async {
    File('${dir.path}/seg_1.ts').writeAsBytesSync(p1);

    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) {
        return _body(200, encMediaPlaylist('').codeUnits);
      }
      if (url.endsWith('/key.bin')) return _body(200, key);
      if (url.endsWith('/seg0.ts')) return _body(200, _encrypt(p0, key, iv));
      if (url.endsWith('/seg2.ts')) return _body(200, _encrypt(p2, key, iv));
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't2',
      entryUrl: 'https://cdn/hls/index.m3u8',
      dir: dir.path,
    );

    expect(r.segmentFiles.length, 3);
    expect(adapter.requested.any((u) => u.endsWith('/seg1.ts')), isFalse);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_2.ts').readAsBytesSync(), p2);
  });

  test('3. 未加密 playlist：分片原样落盘', () async {
    const playlist = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXT-X-ENDLIST
''';
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) return _body(200, playlist.codeUnits);
      if (url.endsWith('/seg0.ts')) return _body(200, p0);
      if (url.endsWith('/seg1.ts')) return _body(200, p1);
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't3',
      entryUrl: 'https://cdn/hls/index.m3u8',
      dir: dir.path,
    );

    expect(r.segmentFiles.length, 2);
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
  });

  test('4. 分片 404 → 刷新 → 重映射 → 成功，finalEntryUrl 为新入口', () async {
    const newEntry = 'https://cdn/hls/new/index.m3u8';
    final adapter = _FakeAdapter((url) {
      // 入口 playlist：新旧各一份，分片前缀不同。
      if (url == 'https://cdn/hls/old/index.m3u8') {
        return _body(200, encMediaPlaylist('').codeUnits);
      }
      if (url == newEntry) {
        return _body(200, encMediaPlaylist('').codeUnits);
      }
      if (url.endsWith('/key.bin')) return _body(200, key);
      // 旧 seg2 过期，新 seg2 成功。
      if (url == 'https://cdn/hls/old/seg2.ts') return _body(404, const []);
      if (url.endsWith('/seg0.ts')) return _body(200, _encrypt(p0, key, iv));
      if (url.endsWith('/seg1.ts')) return _body(200, _encrypt(p1, key, iv));
      if (url.endsWith('/seg2.ts')) return _body(200, _encrypt(p2, key, iv));
      return _body(404, const []);
    });
    final dl = _downloader(adapter, refresh: (_) async => newEntry);

    final r = await dl.download(
      taskId: 't4',
      entryUrl: 'https://cdn/hls/old/index.m3u8',
      dir: dir.path,
    );

    expect(r.finalEntryUrl, newEntry);
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
    expect(File('${dir.path}/seg_2.ts').readAsBytesSync(), p2);
    // 新入口的 seg2 被请求过。
    expect(adapter.requested.contains('https://cdn/hls/new/seg2.ts'), isTrue);
  });

  test('5. master → media hop：跟随 bestVariant 下载', () async {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
high/index.m3u8
''';
    const media = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXT-X-ENDLIST
''';
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/master.m3u8')) return _body(200, master.codeUnits);
      // 只有 high 变体的 media 会被取。
      if (url == 'https://cdn/hls/high/index.m3u8') {
        return _body(200, media.codeUnits);
      }
      if (url == 'https://cdn/hls/high/seg0.ts') return _body(200, p0);
      if (url == 'https://cdn/hls/high/seg1.ts') return _body(200, p1);
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't5',
      entryUrl: 'https://cdn/hls/master.m3u8',
      dir: dir.path,
    );

    expect(r.segmentFiles.length, 2);
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
    expect(
      adapter.requested.contains('https://cdn/hls/high/index.m3u8'),
      isTrue,
    );
  });

  test('6. 下载中取消：抛取消异常、不触发刷新、已下分片保留磁盘', () async {
    final cancel = CancelToken();
    var refreshCalls = 0;
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) {
        return _body(200, encMediaPlaylist('').codeUnits);
      }
      if (url.endsWith('/key.bin')) return _body(200, key);
      if (url.endsWith('/seg0.ts')) return _body(200, _encrypt(p0, key, iv));
      if (url.endsWith('/seg1.ts')) return _body(200, _encrypt(p1, key, iv));
      // 取 seg2 时用户取消：模拟一次被取消的在途请求。
      if (url.endsWith('/seg2.ts')) {
        cancel.cancel('user');
        throw DioException(
          requestOptions: RequestOptions(path: url),
          type: DioExceptionType.cancel,
        );
      }
      return _body(404, const []);
    });
    final dl = _downloader(adapter, refresh: (_) async {
      refreshCalls++;
      return 'https://cdn/hls/should-not-be-used.m3u8';
    });

    await expectLater(
      dl.download(
        taskId: 't6',
        entryUrl: 'https://cdn/hls/index.m3u8',
        dir: dir.path,
        cancelToken: cancel,
      ),
      throwsA(isA<DioException>()
          .having((e) => e.type, 'type', DioExceptionType.cancel)),
    );

    // 取消不应触发刷新。
    expect(refreshCalls, 0);
    // 已下好的分片保留在磁盘；未下的 seg2 不产出。
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
    expect(File('${dir.path}/seg_2.ts').existsSync(), isFalse);
  });

  test('7. 分片空 body：抛错且不产出 0 字节分片文件', () async {
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) {
        return _body(200, encMediaPlaylist('').codeUnits);
      }
      if (url.endsWith('/key.bin')) return _body(200, key);
      if (url.endsWith('/seg0.ts')) return _body(200, _encrypt(p0, key, iv));
      if (url.endsWith('/seg1.ts')) return _body(200, const []); // 异常空 body
      if (url.endsWith('/seg2.ts')) return _body(200, _encrypt(p2, key, iv));
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    await expectLater(
      dl.download(
        taskId: 't7',
        entryUrl: 'https://cdn/hls/index.m3u8',
        dir: dir.path,
      ),
      throwsA(isA<StateError>()),
    );

    // 空 body 不能落成 0 字节文件。
    expect(File('${dir.path}/seg_1.ts').existsSync(), isFalse);
  });

  test('8. BOM playlist：不产生幽灵分片，隐式 IV 按正确 mediaSequence 解密', () async {
    // KEY 不带 IV → 隐式 IV=mediaSequence。BOM 行若被当 URI 会多出幽灵分片，
    // 把真实分片的序号整体 +1 → 解密错乱。
    const playlist = '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MEDIA-SEQUENCE:7\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXTINF:4.0,\nseg0.ts\n'
        '#EXTINF:4.0,\nseg1.ts\n'
        '#EXT-X-ENDLIST\n';
    final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(playlist)];
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) return _body(200, bytes);
      if (url.endsWith('/key.bin')) return _body(200, key);
      if (url.endsWith('/seg0.ts')) {
        return _body(200, _encrypt(p0, key, AesDecryptor.ivFromSequence(7)));
      }
      if (url.endsWith('/seg1.ts')) {
        return _body(200, _encrypt(p1, key, AesDecryptor.ivFromSequence(8)));
      }
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't8',
      entryUrl: 'https://cdn/hls/index.m3u8',
      dir: dir.path,
    );

    expect(r.segmentFiles.length, 2);
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
    expect(File('${dir.path}/seg_1.ts').readAsBytesSync(), p1);
    expect(File('${dir.path}/seg_2.ts').existsSync(), isFalse);
  });

  test('9. 非 ASCII 分片名：解析出单次百分号编码的 URI，不双重编码', () async {
    const playlist = '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4.0,\nsegó.ts\n'
        '#EXT-X-ENDLIST\n';
    final adapter = _FakeAdapter((url) {
      if (url.endsWith('/index.m3u8')) return _body(200, utf8.encode(playlist));
      // ó 的 UTF-8 是 C3 B3：正确的单次编码。双重编码（%C3%83%C2%B3）落到 404。
      if (url == 'https://cdn/hls/seg%C3%B3.ts') return _body(200, p0);
      return _body(404, const []);
    });
    final dl = _downloader(adapter);

    final r = await dl.download(
      taskId: 't9',
      entryUrl: 'https://cdn/hls/index.m3u8',
      dir: dir.path,
    );

    expect(r.segmentFiles.length, 1);
    expect(adapter.requested, contains('https://cdn/hls/seg%C3%B3.ts'));
    expect(File('${dir.path}/seg_0.ts').readAsBytesSync(), p0);
  });

  group('10. 不支持的 playlist 特性 fail-fast：抛明确错误且不发任何分片/key 请求', () {
    Future<void> expectUnsupported(String playlist, String message) async {
      final adapter = _FakeAdapter((url) {
        if (url.endsWith('/index.m3u8')) {
          return _body(200, utf8.encode(playlist));
        }
        if (url.endsWith('.bin')) return _body(200, key);
        return _body(200, _encrypt(p0, key, iv));
      });
      final dl = _downloader(adapter);

      await expectLater(
        dl.download(
          taskId: 'tu',
          entryUrl: 'https://cdn/hls/index.m3u8',
          dir: dir.path,
        ),
        throwsA(isA<UnsupportedPlaylistException>()
            .having((e) => e.message, 'message', contains(message))),
      );
      // fail-fast：除入口 playlist 外没有任何请求（key/分片都不该发）。
      expect(adapter.requested, ['https://cdn/hls/index.m3u8']);
      expect(File('${dir.path}/seg_0.ts').existsSync(), isFalse);
    }

    test('key 轮换（多个不同 EXT-X-KEY）', () async {
      await expectUnsupported(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="k1.bin",IV=0x$ivHex\n'
        '#EXTINF:4.0,\nseg0.ts\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="k2.bin",IV=0x$ivHex\n'
        '#EXTINF:4.0,\nseg1.ts\n'
        '#EXT-X-ENDLIST\n',
        'key 轮换',
      );
    });

    test('METHOD=SAMPLE-AES', () async {
      await expectUnsupported(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="k.bin",IV=0x$ivHex\n'
        '#EXTINF:4.0,\nseg0.ts\n'
        '#EXT-X-ENDLIST\n',
        'SAMPLE-AES',
      );
    });

    test('EXT-X-MAP(fMP4)', () async {
      await expectUnsupported(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:4.0,\nseg0.m4s\n'
        '#EXT-X-ENDLIST\n',
        'EXT-X-MAP',
      );
    });

    test('EXT-X-BYTERANGE', () async {
      await expectUnsupported(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4.0,\n'
        '#EXT-X-BYTERANGE:1000@0\n'
        'all.ts\n'
        '#EXT-X-ENDLIST\n',
        'EXT-X-BYTERANGE',
      );
    });

    test('EXT-X-DISCONTINUITY', () async {
      await expectUnsupported(
        '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:4\n'
        '#EXTINF:4.0,\nseg0.ts\n'
        '#EXT-X-DISCONTINUITY\n'
        '#EXTINF:4.0,\nad0.ts\n'
        '#EXT-X-ENDLIST\n',
        'EXT-X-DISCONTINUITY',
      );
    });
  });
}
