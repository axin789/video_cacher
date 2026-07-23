import 'dart:io';
import 'dart:typed_data';

import 'package:video_cacher/src/log.dart';
import 'package:video_cacher/src/remux/dart_transmuxer/dart_transmuxer.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _tsPacket({
  required int pid,
  required bool pusi,
  required List<int> payload,
  int cc = 0,
}) {
  final pkt = Uint8List(188)..fillRange(0, 188, 0xff);
  pkt[0] = 0x47;
  pkt[1] = (pusi ? 0x40 : 0) | ((pid >> 8) & 0x1f);
  pkt[2] = pid & 0xff;
  pkt[3] = 0x10 | (cc & 0x0f);
  for (int i = 0; i < payload.length && i < 184; i++) {
    pkt[4 + i] = payload[i];
  }
  return pkt;
}

/// adaptation field 填充版：payload 精确为传入字节。
Uint8List _tsPacketAf({
  required int pid,
  required bool pusi,
  required List<int> payload,
  int cc = 0,
}) {
  final pkt = Uint8List(188);
  pkt[0] = 0x47;
  pkt[1] = (pusi ? 0x40 : 0) | ((pid >> 8) & 0x1f);
  pkt[2] = pid & 0xff;
  pkt[3] = 0x30 | (cc & 0x0f);
  final afLen = 184 - payload.length - 1;
  pkt[4] = afLen;
  if (afLen > 0) {
    pkt[5] = 0x00;
    for (int i = 6; i < 5 + afLen; i++) {
      pkt[i] = 0xff;
    }
  }
  pkt.setRange(5 + afLen, 188, payload);
  return pkt;
}

List<int> _pts(int v) => [
      0x21 | (((v >> 30) & 0x7) << 1),
      (v >> 22) & 0xff,
      (((v >> 15) & 0x7f) << 1) | 1,
      (v >> 7) & 0xff,
      ((v & 0x7f) << 1) | 1,
    ];

List<int> _pat() => [
      0x00, 0x00, 0xb0, 0x0d, 0x00, 0x01, 0xc1, 0x00, 0x00, //
      0x00, 0x01, 0xe1, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];

/// PMT：AC-3(0x81) 在前、h264、AAC(0x0f) 在后。
List<int> _pmtMultiAudio() => [
      0x00, 0x02, 0xb0, 0x1c, // section_length = 28
      0x00, 0x01, 0xc1, 0x00, 0x00,
      0xe1, 0x00, 0xf0, 0x00,
      0x81, 0xe1, 0x03, 0xf0, 0x00, // AC-3
      0x1b, 0xe1, 0x01, 0xf0, 0x00, // h264
      0x0f, 0xe1, 0x02, 0xf0, 0x00, // AAC
      0x00, 0x00, 0x00, 0x00,
    ];

// 真实 x264 SPS/PPS（640x360），供 parseSpsDimensions 解析。
const _spsNal = [
  0x67, 0x42, 0xc0, 0x1e, 0xd9, 0x00, 0xa0, 0x2f, 0xf9, 0x61, 0x00, 0x00,
  0x03, 0x00, 0x01, 0x00, 0x00, 0x03, 0x00, 0x32, 0x0f, 0x16, 0x2d, 0x96,
];
const _ppsNal = [0x68, 0xcb, 0x83, 0xcb, 0x20];

List<int> _adtsFrame(List<int> payload) {
  final len = 7 + payload.length;
  return [
    0xff, 0xf1, 0x50,
    0x80 | ((len >> 11) & 0x3),
    (len >> 3) & 0xff,
    ((len & 0x7) << 5) | 0x1f,
    0xfc,
    ...payload,
  ];
}

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

int _countTraks(Uint8List b) {
  int count = 0;
  void walk(int s, int e) {
    int o = s;
    while (o + 8 <= e) {
      final size = _u32(b, o);
      final type = String.fromCharCodes(b, o + 4, o + 8);
      if (type == 'trak') count++;
      if (size < 8) break;
      if (type == 'moov') walk(o + 8, o + size);
      o += size;
    }
  }

  walk(0, b.length);
  return count;
}

void main() {
  group('DartTransmuxer 流类型处理', () {
    late Directory tmp;

    setUp(() async {
      VideoCacherLog.verbose = false;
      tmp = await Directory.systemTemp.createTemp('transmux_ff_');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('首分片见到 h265 PMT 立即失败，不读后续分片', () async {
      final seg1 = File('${tmp.path}/seg1.ts');
      final b = BytesBuilder(copy: false);
      b.add(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      final pmt = _pmtMultiAudio();
      pmt[18] = 0x24; // video stream_type -> hevc
      b.add(_tsPacket(pid: 0x0100, pusi: true, payload: pmt));
      await seg1.writeAsBytes(b.toBytes());

      // 第二片路径不存在：若被读取会得到 FileSystemException 而非 Unsupported
      final missing = '${tmp.path}/no_such_seg2.ts';
      final res = await DartTransmuxer().remux(
        taskId: 't1',
        segmentFiles: [seg1.path, missing],
        outMp4: '${tmp.path}/out.mp4',
        dir: tmp.path,
      );
      expect(res.ok, isFalse);
      expect(res.error, contains('only h264+aac supported'));
      expect(res.error, contains('0x24'));
    });

    test('AC-3 在前的多音轨流选中 AAC 并成功转封装', () async {
      final b = BytesBuilder(copy: false);
      b.add(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      b.add(_tsPacket(pid: 0x0100, pusi: true, payload: _pmtMultiAudio()));
      // AC-3 pid 上喂垃圾，若被选中会产出不了 AAC
      b.add(_tsPacket(pid: 0x0103, pusi: true, payload: [0x0b, 0x77, 0x00]));
      // video：SPS+PPS+IDR，再一帧非 IDR
      for (int f = 0; f < 2; f++) {
        final au = <int>[
          if (f == 0) ...[
            0x00, 0x00, 0x00, 0x01, ..._spsNal,
            0x00, 0x00, 0x00, 0x01, ..._ppsNal,
          ],
          0x00, 0x00, 0x00, 0x01, f == 0 ? 0x65 : 0x41, 0x88, 0x84, 0x21,
        ];
        b.add(_tsPacketAf(pid: 0x0101, pusi: true, cc: f, payload: [
          0x00, 0x00, 0x01, 0xe0, 0x00, 0x00,
          0x80, 0x80, 0x05, ..._pts(90000 + f * 3600),
          ...au,
        ]));
      }
      // audio：一个 PES 两帧 ADTS
      b.add(_tsPacketAf(pid: 0x0102, pusi: true, payload: [
        0x00, 0x00, 0x01, 0xc0, 0x00, 0x00,
        0x80, 0x80, 0x05, ..._pts(90000),
        ..._adtsFrame(List.filled(13, 0x11)),
        ..._adtsFrame(List.filled(13, 0x22)),
      ]));

      final seg = File('${tmp.path}/seg.ts');
      await seg.writeAsBytes(b.toBytes());
      final out = '${tmp.path}/out.mp4';
      final res = await DartTransmuxer().remux(
        taskId: 't2',
        segmentFiles: [seg.path],
        outMp4: out,
        dir: tmp.path,
      );
      expect(res.ok, isTrue, reason: res.error);
      final bytes = await File(out).readAsBytes();
      expect(_countTraks(bytes), 2); // video + AAC audio
    });
  });
}
