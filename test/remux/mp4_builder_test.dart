import 'dart:typed_data';

import 'package:video_cacher/src/remux/dart_transmuxer/aac_adts.dart';
import 'package:video_cacher/src/remux/dart_transmuxer/mp4_builder.dart';
import 'package:flutter_test/flutter_test.dart';

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

/// 全文件字节扫描某 4CC（用于 avc1/mp4a 内的样本条目子盒，避免解析其定长头部）。
bool _hasFourCC(Uint8List b, String cc) {
  final t = cc.codeUnits;
  for (int i = 0; i + 4 <= b.length; i++) {
    if (b[i] == t[0] && b[i + 1] == t[1] && b[i + 2] == t[2] && b[i + 3] == t[3]) {
      return true;
    }
  }
  return false;
}

const Set<String> _containers = {
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf', //
};

/// 递归收集所有 box 类型（用于断言结构存在）。
void _collectTypes(Uint8List b, int start, int end, List<String> out) {
  int o = start;
  while (o + 8 <= end) {
    final size = _u32(b, o);
    final type = String.fromCharCodes(b, o + 4, o + 8);
    out.add(type);
    if (size < 8) break;
    if (_containers.contains(type)) {
      _collectTypes(b, o + 8, o + size, out);
    }
    o += size;
  }
}

/// 找到第一个匹配类型的 box，返回其 payload 起始 offset（跳过 8 字节 header）。
int? _findBox(Uint8List b, int start, int end, String target) {
  int o = start;
  while (o + 8 <= end) {
    final size = _u32(b, o);
    final type = String.fromCharCodes(b, o + 4, o + 8);
    if (type == target) return o + 8;
    if (size < 8) break;
    if (_containers.contains(type)) {
      final r = _findBox(b, o + 8, o + size, target);
      if (r != null) return r;
    }
    o += size;
  }
  return null;
}

/// 收集全部匹配类型 box 的 payload 起始 offset（按出现顺序）。
List<int> _findBoxAll(Uint8List b, String target) {
  final out = <int>[];
  void walk(int s, int e) {
    int o = s;
    while (o + 8 <= e) {
      final size = _u32(b, o);
      final type = String.fromCharCodes(b, o + 4, o + 8);
      if (type == target) out.add(o + 8);
      if (size < 8) break;
      if (_containers.contains(type)) walk(o + 8, o + size);
      o += size;
    }
  }

  walk(0, b.length);
  return out;
}

/// 全文件字节扫描某 4CC 的首个出现位置（用于 stsd 内的样本条目）。
int? _fourCCIndex(Uint8List b, String cc) {
  final t = cc.codeUnits;
  for (int i = 0; i + 4 <= b.length; i++) {
    if (b[i] == t[0] && b[i + 1] == t[1] && b[i + 2] == t[2] && b[i + 3] == t[3]) {
      return i;
    }
  }
  return null;
}

void main() {
  // 最小 SPS/PPS（结构测试只用到前 4 字节生成 avcC）。
  final sps = Uint8List.fromList([0x67, 0x42, 0x00, 0x1e, 0x11, 0x22]);
  final pps = Uint8List.fromList([0x68, 0xce, 0x3c, 0x80]);

  // B 帧重排：解码顺序 dts 递增，pts 有前后交错（pts>dts 出现）。
  final samples = <VideoSample>[
    VideoSample(Uint8List(100), 0, 0, true), // I: pts==dts
    VideoSample(Uint8List(80), 3000, 1000, false), // P: pts>dts
    VideoSample(Uint8List(60), 1000, 2000, false), // B: pts<dts
    VideoSample(Uint8List(60), 2000, 3000, false), // B
  ];
  final aac = AacInfo(
    [Uint8List(50), Uint8List(50), Uint8List(50)],
    2, // AOT LC
    4, // 44100
    2, // stereo
  );

  late Uint8List out;
  setUp(() {
    final r = buildMp4(
      vsamples: samples,
      sps: sps,
      pps: pps,
      width: 320,
      height: 240,
      aac: aac,
      firstAudioPts: 0,
    );
    out = r.bytes;
  });

  group('buildMp4 结构', () {
    test('顶层 ftyp/mdat/moov 齐全且有序', () {
      final top = <String>[];
      _collectTypes(out, 0, out.length, top);
      final ftyp = top.indexOf('ftyp');
      final mdat = top.indexOf('mdat');
      final moov = top.indexOf('moov');
      expect(ftyp, 0);
      expect(mdat >= 0, isTrue);
      expect(moov > mdat, isTrue);
    });

    test('含 elst / ctts / stss（关键 box）', () {
      final types = <String>[];
      _collectTypes(out, 0, out.length, types);
      expect(types, contains('elst'));
      expect(types, contains('ctts'));
      expect(types, contains('stss'));
      expect(_hasFourCC(out, 'avcC'), isTrue);
      expect(_hasFourCC(out, 'esds'), isTrue);
    });

    test('两条 trak（video+audio）', () {
      final types = <String>[];
      _collectTypes(out, 0, out.length, types);
      expect(types.where((t) => t == 'trak').length, 2);
    });

    test('video stsz sample_count == 帧数', () {
      // 第一个 stsz 属于 video trak（先 build video）。
      final o = _findBox(out, 0, out.length, 'stsz');
      expect(o, isNotNull);
      // fullbox: version+flags(4) + sample_size(4) + sample_count(4)
      final count = _u32(out, o! + 8);
      expect(count, samples.length);
    });

    test('ctts 存在时 elst media_time = 最小 composition offset', () {
      final r = buildMp4(
        vsamples: samples,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac,
        firstAudioPts: 0,
      );
      // 样本含 pts<dts（最小 offset=-1000）：DTS 整体平移后 ctts 全部非负，
      // mediaStart = minPts - vDts[0] = 0 - (-1000) = 1000；空编辑仍 = minPts = 0
      expect(r.mediaStart, 1000);
      expect(r.emptyEditDur, 0);
      // ctts[0] = pts-dts 平移后：I=1000, P=3000, B=0...
      expect(r.firstCtts.first, 1000);
      // 存在非零 ctts（B 帧）
      expect(r.firstCtts.any((c) => c != 0), isTrue);
    });

    test('pts<dts 时 ctts 不下溢（u32 全部 < 2^31）', () {
      final bad = <VideoSample>[
        VideoSample(Uint8List(10), 0, 0, true),
        VideoSample(Uint8List(10), 2900, 3000, false), // pts < dts
        VideoSample(Uint8List(10), 6000, 6000, false),
      ];
      final r = buildMp4(
        vsamples: bad,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac,
        firstAudioPts: 0,
      );
      final o = _findBox(r.bytes, 0, r.bytes.length, 'ctts')!;
      final n = _u32(r.bytes, o + 4);
      expect(n, greaterThan(0));
      for (int i = 0; i < n; i++) {
        final off = _u32(r.bytes, o + 8 + i * 8 + 4);
        expect(off, lessThan(0x80000000), reason: 'ctts[$i]=$off 下溢');
      }
    });

    test('无关键帧时省略 stss（缺省 = 全部 sync）', () {
      final noKey = <VideoSample>[
        VideoSample(Uint8List(10), 0, 0, false),
        VideoSample(Uint8List(10), 3000, 3000, false),
      ];
      final r = buildMp4(
        vsamples: noKey,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac,
        firstAudioPts: 0,
      );
      final types = <String>[];
      _collectTypes(r.bytes, 0, r.bytes.length, types);
      expect(types, isNot(contains('stss')));
    });

    test('audio tkhd duration 用 movie timescale 而非采样数', () {
      // 100 帧 AAC@44100 = 102400 采样 -> movie(90000) = 208979
      final aac100 = AacInfo(List.generate(100, (_) => Uint8List(8)), 2, 4, 2);
      final r = buildMp4(
        vsamples: samples,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac100,
        firstAudioPts: 0,
      );
      final tkhds = _findBoxAll(r.bytes, 'tkhd');
      expect(tkhds.length, 2);
      // fullbox v0: verflags(4) creation(4) mod(4) trackid(4) reserved(4) dur(4)
      final audioTkhdDur = _u32(r.bytes, tkhds[1] + 4 + 16);
      expect(audioTkhdDur, (100 * 1024 * 90000) ~/ 44100);
      final mvhdOff = _findBox(r.bytes, 0, r.bytes.length, 'mvhd')!;
      final mvhdDur = _u32(r.bytes, mvhdOff + 4 + 12);
      expect(mvhdDur, greaterThanOrEqualTo(audioTkhdDur));
    });

    test('sampleRate >= 65536 时 mp4a 采样率字段写 0（esds 为准）', () {
      final aac96k = AacInfo([Uint8List(8)], 2, 0, 2); // freqIndex 0 = 96000
      final r = buildMp4(
        vsamples: samples,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac96k,
        firstAudioPts: 0,
      );
      // mp4a payload 前 24 字节后是 16.16 采样率的高 16 位
      final i = _fourCCIndex(r.bytes, 'mp4a')!;
      final rateHi = (r.bytes[i + 28] << 8) | r.bytes[i + 29];
      expect(rateHi, 0);
    });
  });

  group('buildMp4 时间基线', () {
    test('音频先起时用全局基线并产生非零空编辑', () {
      // audio 首 PTS 早于 video 首 DTS（video dts0=0，这里 audio=-900 不合法，
      // 用 video dts 抬高来模拟：让 video 全部 +900，audio 基线 0）。
      final shifted = samples
          .map((s) => VideoSample(s.data, s.pts + 900, s.dts + 900, s.keyframe))
          .toList();
      final r = buildMp4(
        vsamples: shifted,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac,
        firstAudioPts: 0, // audio 更早
      );
      // globalMin=0 -> video 首 dts 相对基线=900；minPts=900 -> 空编辑=900
      expect(r.emptyEditDur, 900);
    });

    test('视频 DTS 早于音频 PTS 时，空编辑用 PTS 而非被 DTS 污染', () {
      // 真实点播样本形态：含 B 帧，视频首个 DTS(126000) < 音频首 PTS(129910)，
      // 视频最小 PTS = 132000（reorder 延迟 6000）。
      final real = <VideoSample>[
        VideoSample(Uint8List(100), 132000, 126000, true), // I: pts>dts
        VideoSample(Uint8List(80), 138000, 129000, false), // P
        VideoSample(Uint8List(60), 135000, 132000, false), // B
      ];
      final r = buildMp4(
        vsamples: real,
        sps: sps,
        pps: pps,
        width: 320,
        height: 240,
        aac: aac,
        firstAudioPts: 129910,
      );
      // 正确：globalMin=min(129910,132000)=129910 -> dEmpty=132000-129910=2090
      expect(r.emptyEditDur, 132000 - 129910); // 2090
      // 若基线被 DTS 污染（globalMin=126000）会得到 6000，必须不是这个值
      expect(r.emptyEditDur, isNot(6000));
      // mediaStart 与基线无关，恒为 reorder 延迟 6000
      expect(r.mediaStart, 6000);
    });
  });
}
