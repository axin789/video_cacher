import 'dart:async';
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

/// 第一个 stsz（video trak 在前）的 sample_count。
int _videoSampleCount(Uint8List b) {
  const containers = {'moov', 'trak', 'mdia', 'minf', 'stbl'};
  int? found;
  void walk(int s, int e) {
    int o = s;
    while (o + 8 <= e && found == null) {
      final size = _u32(b, o);
      final type = String.fromCharCodes(b, o + 4, o + 8);
      // fullbox: verflags(4) + sample_size(4) + sample_count(4)
      if (type == 'stsz') {
        found = _u32(b, o + 8 + 8);
        return;
      }
      if (size < 8) break;
      if (containers.contains(type)) walk(o + 8, o + size);
      o += size;
    }
  }

  walk(0, b.length);
  return found ?? -1;
}

void main() {
  group('DartTransmuxer isolate 行为', () {
    final fixture = File('test/fixtures/ts/h264_aac.ts');
    late Directory tmp;

    setUp(() async {
      VideoCacherLog.verbose = false;
      tmp = await Directory.systemTemp.createTemp('transmux_iso_');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('多分片输入：onProgress 回报递增的累计输入字节', () async {
      // 把 fixture 按 188 字节包边界切成 3 个分片
      final bytes = await fixture.readAsBytes();
      final third = (bytes.length ~/ 188 ~/ 3) * 188;
      final parts = [
        bytes.sublist(0, third),
        bytes.sublist(third, third * 2),
        bytes.sublist(third * 2),
      ];
      final segFiles = <String>[];
      for (var i = 0; i < parts.length; i++) {
        final f = File('${tmp.path}/seg_$i.ts');
        await f.writeAsBytes(parts[i]);
        segFiles.add(f.path);
      }

      final progress = <int>[];
      final out = '${tmp.path}/out.mp4';
      final res = await DartTransmuxer().remux(
        taskId: 'p',
        segmentFiles: segFiles,
        outMp4: out,
        dir: tmp.path,
        onProgress: progress.add,
      );
      expect(res.ok, isTrue, reason: res.error);
      expect(progress.length, greaterThanOrEqualTo(2),
          reason: '每喂完一个分片应回报一次');
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]), reason: '应单调递增');
      }
      expect(progress.last, bytes.length, reason: '最终值应为输入总字节');
      expect(File(out).existsSync(), isTrue);
    });

    test('remux 进行中 cancel：强杀 worker，结果 canceled，无 out 也无 .part',
        () async {
      // 用 fixture 重复拼接构造较大的 4 片输入，保证 worker 跑得够久
      final base = await fixture.readAsBytes();
      final big = BytesBuilder(copy: false);
      for (var i = 0; i < 100; i++) {
        big.add(base);
      }
      final segBytes = big.takeBytes(); // ~4.8MB/片
      final segFiles = <String>[];
      for (var i = 0; i < 4; i++) {
        final f = File('${tmp.path}/big_$i.ts');
        await f.writeAsBytes(segBytes);
        segFiles.add(f.path);
      }

      final mux = DartTransmuxer();
      final out = '${tmp.path}/out.mp4';
      final firstProgress = Completer<void>();
      final future = mux.remux(
        taskId: 'c',
        segmentFiles: segFiles,
        outMp4: out,
        dir: tmp.path,
        onProgress: (_) {
          if (!firstProgress.isCompleted) firstProgress.complete();
        },
      );
      // 首个进度到达 = worker 正在流水线中途（还剩 3 片 + 构建），此时取消
      await firstProgress.future;
      mux.cancel('c');

      final res = await future;
      expect(res.ok, isFalse);
      expect(res.error, 'canceled');
      expect(File(out).existsSync(), isFalse, reason: '不应产出 mp4');
      expect(File('$out.part').existsSync(), isFalse,
          reason: '取消后应清理 .part');
      expect(File('$out.v.es').existsSync(), isFalse,
          reason: '取消后应清理视频 ES 临时文件');
      expect(File('$out.a.es').existsSync(), isFalse,
          reason: '取消后应清理音频 ES 临时文件');
    });
  });

  group('两遍流式转封装', () {
    final fixture = File('test/fixtures/ts/h264_aac.ts');
    late Directory tmp;

    setUp(() async {
      VideoCacherLog.verbose = false;
      tmp = await Directory.systemTemp.createTemp('transmux_es_');
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Future<Uint8List> remuxOk(String name, List<String> segs) async {
      final out = '${tmp.path}/$name.mp4';
      final res = await DartTransmuxer().remux(
        taskId: name,
        segmentFiles: segs,
        outMp4: out,
        dir: tmp.path,
      );
      expect(res.ok, isTrue, reason: res.error);
      return File(out).readAsBytes();
    }

    test('成功后无 .v.es/.a.es/.part 残留', () async {
      final out = '${tmp.path}/clean.mp4';
      final res = await DartTransmuxer().remux(
        taskId: 'clean',
        segmentFiles: [fixture.path],
        outMp4: out,
        dir: tmp.path,
      );
      expect(res.ok, isTrue, reason: res.error);
      expect(File(out).existsSync(), isTrue);
      expect(File('$out.part').existsSync(), isFalse);
      expect(File('$out.v.es').existsSync(), isFalse,
          reason: '成功后应删除视频 ES 临时文件');
      expect(File('$out.a.es').existsSync(), isFalse,
          reason: '成功后应删除音频 ES 临时文件');
    });

    test('分片在非 AU 对齐的 188 边界拆开：产物与单段逐字节一致', () async {
      // AU 跨多个 TS 包：任取一个流中段的包边界拆分，AU 必然横跨两段
      // （跨多次 drain），锁住增量转出与单次喂入的等价性。
      final bytes = await fixture.readAsBytes();
      const splitAt = 101 * 188;
      final seg0 = File('${tmp.path}/s0.ts')
        ..writeAsBytesSync(bytes.sublist(0, splitAt));
      final seg1 = File('${tmp.path}/s1.ts')
        ..writeAsBytesSync(bytes.sublist(splitAt));

      final whole = await remuxOk('whole', [fixture.path]);
      final split = await remuxOk('split', [seg0.path, seg1.path]);
      expect(split, whole, reason: '多段喂入必须与单段产物逐字节一致');
    });

    test('有界 PES 续包跨分片边界：并回上一单元，不多算帧', () async {
      // AU：SPS+PPS+IDR，拆成 PES1（带 PTS，前 30 字节）+ PES2（续包无 PTS）。
      // seg1 里 PES2 的 PUSI 已把 PES1 封口（进 units 但尚未取走），续包本体
      // 落在 seg2——若 drain 把最近封口单元也取走，续包将无处并回。
      final au = <int>[
        0x00, 0x00, 0x00, 0x01, ..._spsNal,
        0x00, 0x00, 0x00, 0x01, ..._ppsNal,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x21,
      ];
      const cut = 30;
      final part1 = au.sublist(0, cut);
      final part2 = au.sublist(cut);
      final pes1 = _tsPacketAf(pid: 0x0101, pusi: true, payload: [
        0x00, 0x00, 0x01, 0xe0,
        0x00, 3 + 5 + part1.length, // 有界 PES_packet_length
        0x80, 0x80, 0x05, ..._pts(90000),
        ...part1,
      ]);
      final pes2 = _tsPacketAf(pid: 0x0101, pusi: true, cc: 1, payload: [
        0x00, 0x00, 0x01, 0xe0,
        0x00, 3 + part2.length,
        0x80, 0x00, 0x00, // 无 pts/dts 的续包
        ...part2,
      ]);
      final pes3 = _tsPacketAf(pid: 0x0101, pusi: true, cc: 2, payload: [
        0x00, 0x00, 0x01, 0xe0, 0x00, 0x00,
        0x80, 0x80, 0x05, ..._pts(90000 + 3600),
        0x00, 0x00, 0x00, 0x01, 0x41, 0x88, 0x84, 0x21,
      ]);
      final audio = _tsPacketAf(pid: 0x0102, pusi: true, payload: [
        0x00, 0x00, 0x01, 0xc0, 0x00, 0x00,
        0x80, 0x80, 0x05, ..._pts(90000),
        ..._adtsFrame(List.filled(13, 0x11)),
        ..._adtsFrame(List.filled(13, 0x22)),
      ]);
      final head = BytesBuilder(copy: false)
        ..add(_tsPacket(pid: 0, pusi: true, payload: _pat()))
        ..add(_tsPacket(pid: 0x0100, pusi: true, payload: _pmtMultiAudio()))
        ..add(pes1)
        ..add(pes2);
      final tail = BytesBuilder(copy: false)
        ..add(pes3)
        ..add(audio);
      final headBytes = head.takeBytes();
      final tailBytes = tail.takeBytes();

      final seg1 = File('${tmp.path}/c0.ts')..writeAsBytesSync(headBytes);
      final seg2 = File('${tmp.path}/c1.ts')..writeAsBytesSync(tailBytes);
      final whole = File('${tmp.path}/cw.ts')
        ..writeAsBytesSync([...headBytes, ...tailBytes]);

      final split = await remuxOk('csplit', [seg1.path, seg2.path]);
      final single = await remuxOk('cwhole', [whole.path]);
      expect(split, single, reason: '跨分片续包必须与单段产物逐字节一致');
      // 视频恰好 2 帧（续包并回，不成为第三帧）
      expect(_videoSampleCount(split), 2);
    });
  });

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
