import 'dart:typed_data';

import 'package:video_cacher/src/remux/dart_transmuxer/aac_adts.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个 ADTS 帧（LC、44.1k、立体声、无 CRC）：7 字节头 + [payload]。
Uint8List _frame(List<int> payload) {
  final len = 7 + payload.length;
  return Uint8List.fromList([
    0xff, 0xf1, 0x50,
    0x80 | ((len >> 11) & 0x3), // channel_configuration=2（高位在 0x50 末位）
    (len >> 3) & 0xff,
    ((len & 0x7) << 5) | 0x1f,
    0xfc,
    ...payload,
  ]);
}

void main() {
  group('AdtsStream', () {
    final f1 = _frame(List.generate(100, (i) => 0xa0 | (i & 0xf)));
    final f2 = _frame(List.generate(90, (i) => 0xb0 | (i & 0xf)));
    final f3 = _frame(List.generate(80, (i) => 0xc0 | (i & 0xf)));
    final all = Uint8List.fromList([...f1, ...f2, ...f3]);

    // 按绝对偏移把整串切成多段 payload（模拟 PES 边界）。
    List<Uint8List> split(List<int> cuts) {
      final out = <Uint8List>[];
      int prev = 0;
      for (final c in [...cuts, all.length]) {
        out.add(Uint8List.sublistView(all, prev, c));
        prev = c;
      }
      return out;
    }

    // 逐段喂入，收集全部帧（跨段 carry 由 AdtsStream 内部维护）。
    (AdtsStream, List<Uint8List>) feedAll(List<Uint8List> payloads) {
      final s = AdtsStream();
      final frames = <Uint8List>[];
      for (final p in payloads) {
        frames.addAll(s.feed(p).map(Uint8List.fromList));
      }
      return (s, frames);
    }

    void expectAllFrames(List<Uint8List> payloads) {
      final (s, frames) = feedAll(payloads);
      expect(frames.length, 3);
      expect(frames[0], f1.sublist(7));
      expect(frames[1], f2.sublist(7));
      expect(frames[2], f3.sublist(7));
      final track = s.track;
      expect(track, isNotNull);
      expect(track!.frameSizes, [100, 90, 80]);
      expect(track.sampleRate, 44100);
      expect(track.channels, 2);
    }

    test('单段完整解析（基线）', () {
      expectAllFrames([all]);
    });

    test('帧体跨 PES 边界不丢帧', () {
      expectAllFrames(split([f1.length + 40]));
    });

    test('帧头跨 PES 边界（syncword 后不足 7 字节）不丢帧', () {
      expectAllFrames(split([f1.length + 3]));
    });

    test('多处刁钻切点组合（头 1 字节 + 尾部 6 字节）', () {
      expectAllFrames(split([f1.length + 1, f1.length + f2.length + 6]));
    });

    test('假 syncword（frameLen<7）不吞掉后续帧', () {
      final junk = [0xff, 0xf1, 0x00, 0x00, 0x00, 0x00, 0x00];
      final (s, frames) = feedAll([
        Uint8List.fromList([...junk, ...f1]),
      ]);
      expect(frames.length, 1);
      expect(frames[0], f1.sublist(7));
      expect(s.track, isNotNull);
    });

    test('无可解码帧时 track 为 null', () {
      final s = AdtsStream();
      expect(s.feed(Uint8List.fromList([0x00, 0x11, 0x22])), isEmpty);
      expect(s.track, isNull);
    });
  });
}
