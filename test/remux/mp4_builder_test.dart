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
      // 首个呈现 PTS=0（I 帧），dts[0]=0 -> mediaStart=0；空编辑 dEmpty=minPts=0
      expect(r.mediaStart, 0);
      expect(r.emptyEditDur, 0);
      // ctts[0] = pts-dts；I=0, P=2000, B=-1000...
      expect(r.firstCtts.first, 0);
      // 存在非零 ctts（B 帧）
      expect(r.firstCtts.any((c) => c != 0), isTrue);
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
