import 'package:flutter_test/flutter_test.dart';
import 'package:ffmpeg_remux/src/download/hls/m3u8_parser.dart';

void main() {
  final parser = M3u8Parser();

  group('media playlist', () {
    test('AES-128 + 显式 IV + 绝对签名 URI（含 ~ & =）', () {
      const content = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:11
#EXT-X-MEDIA-SEQUENCE:0
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/enc.key?Expires=123&Signature=abc~def&Key-Pair-Id=K3",IV=0x64cf692cebc516e4a86ac6081aae50ce
#EXTINF:10.566667,
https://cdn.example.com/hls/seg-m0.ts?Expires=123&Signature=xyz~&Key-Pair-Id=K3
#EXTINF:9.666667,
https://cdn.example.com/hls/seg-m1.ts?Expires=123&Signature=uvw~&Key-Pair-Id=K3
#EXT-X-ENDLIST
''';
      final p = parser.parse(content, baseUri: 'https://cdn.example.com/hls/index.m3u8');

      expect(p.isMaster, isFalse);
      expect(p.hasEndList, isTrue);
      expect(p.targetDurationMs, 11000);
      expect(p.segments.length, 2);

      expect(p.segments[0].uri,
          'https://cdn.example.com/hls/seg-m0.ts?Expires=123&Signature=xyz~&Key-Pair-Id=K3');
      expect(p.segments[0].uri, contains('Signature=xyz~'));
      expect(p.segments[0].durationMs, 10567);
      expect(p.segments[1].uri, contains('Signature=uvw~'));
      expect(p.segments[1].durationMs, 9667);

      final key = p.key!;
      expect(key.method, 'AES-128');
      expect(key.uri,
          'https://cdn.example.com/enc.key?Expires=123&Signature=abc~def&Key-Pair-Id=K3');
      expect(key.uri, contains('Signature=abc~def'));
      expect(key.ivHex, '64cf692cebc516e4a86ac6081aae50ce');
    });

    test('相对分片 URI 归一到 baseUri', () {
      const content = '''
#EXTM3U
#EXTINF:5.0,
seg0.ts
#EXTINF:5.0,
seg1.ts
#EXT-X-ENDLIST
''';
      final p = parser.parse(content, baseUri: 'https://h/path/index.m3u8');
      expect(p.segments[0].uri, 'https://h/path/seg0.ts');
      expect(p.segments[1].uri, 'https://h/path/seg1.ts');
    });

    test('无 EXT-X-KEY → key 为 null，分片未加密', () {
      const content = '''
#EXTM3U
#EXTINF:5.0,
seg0.ts
#EXT-X-ENDLIST
''';
      final p = parser.parse(content, baseUri: 'https://h/path/index.m3u8');
      expect(p.key, isNull);
      expect(p.segments.length, 1);
    });

    test('MEDIA-SEQUENCE 非零 → mediaSequence == base + index', () {
      const content = '''
#EXTM3U
#EXT-X-MEDIA-SEQUENCE:42
#EXTINF:5.0,
seg0.ts
#EXTINF:5.0,
seg1.ts
''';
      final p = parser.parse(content, baseUri: 'https://h/p/i.m3u8');
      expect(p.segments[0].mediaSequence, 42);
      expect(p.segments[1].mediaSequence, 43);
    });

    test('KEY 的 URI 内含逗号（在引号内）不破坏属性解析', () {
      const content = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/enc.key?a=1,2,3&b=x",IV=0xabcdef00112233445566778899aabbcc
#EXTINF:5.0,
seg0.ts
#EXT-X-ENDLIST
''';
      final p = parser.parse(content, baseUri: 'https://cdn.example.com/hls/i.m3u8');
      final key = p.key!;
      expect(key.method, 'AES-128');
      expect(key.uri, 'https://cdn.example.com/enc.key?a=1,2,3&b=x');
      expect(key.ivHex, 'abcdef00112233445566778899aabbcc');
    });

    test('\\r\\n 行尾容忍', () {
      const content =
          '#EXTM3U\r\n#EXTINF:3.0,\r\nseg0.ts\r\n#EXT-X-ENDLIST\r\n';
      final p = parser.parse(content, baseUri: 'https://h/p/i.m3u8');
      expect(p.segments.length, 1);
      expect(p.segments[0].uri, 'https://h/p/seg0.ts');
      expect(p.segments[0].durationMs, 3000);
    });
  });

  group('master playlist', () {
    test('多个 STREAM-INF（含相对 URI）→ bestVariant 取最高带宽', () {
      const content = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
https://cdn.example.com/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080
high/index.m3u8
''';
      final p = parser.parse(content, baseUri: 'https://cdn.example.com/master.m3u8');
      expect(p.isMaster, isTrue);
      expect(p.variants.length, 2);

      expect(p.variants[0].bandwidth, 800000);
      expect(p.variants[0].resolution, '640x360');
      expect(p.variants[0].uri, 'https://cdn.example.com/low.m3u8');

      expect(p.variants[1].bandwidth, 2400000);
      expect(p.variants[1].resolution, '1920x1080');
      expect(p.variants[1].uri, 'https://cdn.example.com/high/index.m3u8');

      expect(p.bestVariant!.bandwidth, 2400000);
      expect(p.bestVariant!.uri, 'https://cdn.example.com/high/index.m3u8');
    });
  });
}
