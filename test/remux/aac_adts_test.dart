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
  group('parseAdts', () {
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

    void expectAllFrames(AacInfo? info) {
      expect(info, isNotNull);
      expect(info!.frames.length, 3);
      expect(info.frames[0], f1.sublist(7));
      expect(info.frames[1], f2.sublist(7));
      expect(info.frames[2], f3.sublist(7));
      expect(info.sampleRate, 44100);
      expect(info.channels, 2);
    }

    test('单段完整解析（基线）', () {
      expectAllFrames(parseAdts([all]));
    });

    test('帧体跨 PES 边界不丢帧', () {
      expectAllFrames(parseAdts(split([f1.length + 40])));
    });

    test('帧头跨 PES 边界（syncword 后不足 7 字节）不丢帧', () {
      expectAllFrames(parseAdts(split([f1.length + 3])));
    });

    test('多处刁钻切点组合（头 1 字节 + 尾部 6 字节）', () {
      expectAllFrames(
          parseAdts(split([f1.length + 1, f1.length + f2.length + 6])));
    });

    test('假 syncword（frameLen<7）不吞掉后续帧', () {
      final junk = [0xff, 0xf1, 0x00, 0x00, 0x00, 0x00, 0x00];
      final info = parseAdts([
        Uint8List.fromList([...junk, ...f1]),
      ]);
      expect(info, isNotNull);
      expect(info!.frames.length, 1);
      expect(info.frames[0], f1.sublist(7));
    });
  });
}
