import 'dart:typed_data';

import 'aac_adts.dart';
import 'h264_parser.dart';

/// 一帧视频样本：AVCC（4 字节长度前缀）数据 + 时间戳 + 是否关键帧。
class VideoSample {
  final Uint8List data; // AVCC length-prefixed
  final int pts;
  final int dts;
  final bool keyframe;
  const VideoSample(this.data, this.pts, this.dts, this.keyframe);
}

/// mp4 构建产物 + 供日志/校验用的关键统计。
class Mp4BuildResult {
  final Uint8List bytes;
  final int mdatSize;
  final int moovSize;
  final int videoTimescale;
  final int firstPts;
  final int firstDts;
  final int emptyEditDur; // elst 空编辑时长（movie timescale）
  final int mediaStart; // elst media_time
  final int videoTotalDur;
  final List<int> firstCtts;

  const Mp4BuildResult({
    required this.bytes,
    required this.mdatSize,
    required this.moovSize,
    required this.videoTimescale,
    required this.firstPts,
    required this.firstDts,
    required this.emptyEditDur,
    required this.mediaStart,
    required this.videoTotalDur,
    required this.firstCtts,
  });
}

// ---------- byte writers ----------
void _wU32(BytesBuilder b, int v) =>
    b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);

List<int> _u32(int v) =>
    [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];
List<int> _u16(int v) => [(v >> 8) & 0xff, v & 0xff];

Uint8List _box(String type, List<int> payload) {
  final b = BytesBuilder(copy: false);
  _wU32(b, 8 + payload.length);
  b.add(type.codeUnits);
  b.add(payload);
  return b.toBytes();
}

Uint8List _fullbox(String type, int version, int flags, List<int> payload) {
  final b = BytesBuilder(copy: false);
  b.add([version, (flags >> 16) & 0xff, (flags >> 8) & 0xff, flags & 0xff]);
  b.add(payload);
  return _box(type, b.toBytes());
}

/// 用已解析好的 video 样本 + audio 帧，构建一个 fragmented-free 的 mp4。
///
/// 时间基线与 edit list 复刻已验证原型（framemd5 与 `ffmpeg -c copy` 逐帧一致）：
/// A/V 两轨统一以「全局最小 PTS」为基线，视频用空编辑 + media 编辑
/// （media_time = 最小 composition offset）对齐，B 帧用 ctts 表达。
///
/// 当前 VOD 场景的硬限制（未处理，业务需知）：
///  - PTS 33-bit 环绕未处理：超长流 PTS 回绕会导致时间戳错乱。
///  - 单个 mdat 用 32 位 size + stco 用 32 位偏移：>4GB 产物会溢出（未写 co64）。
///  - 整流入内存（mdat/样本表全量驻留）：超长/超大片会 OOM。
Mp4BuildResult buildMp4({
  required List<VideoSample> vsamples,
  required Uint8List sps,
  required Uint8List pps,
  required int width,
  required int height,
  required AacInfo aac,
  required int firstAudioPts,
}) {
  // decode order = DTS 升序（TS 通常已如此，排序兜底）
  final vs = List<VideoSample>.from(vsamples)
    ..sort((a, b) => a.dts.compareTo(b.dts));

  // ---- mdat：先 video chunk 再 audio chunk ----
  final mdatBody = BytesBuilder(copy: false);
  final vSizes = <int>[];
  for (final s in vs) {
    mdatBody.add(s.data);
    vSizes.add(s.data.length);
  }
  final vChunkSize = vSizes.fold<int>(0, (a, b) => a + b);
  final aSizes = <int>[];
  for (final f in aac.frames) {
    mdatBody.add(f);
    aSizes.add(f.length);
  }
  final mdat = mdatBody.toBytes();

  // ---- video timing ----
  // 呈现基线只能用 PTS，绝不能混入 DTS：含 B 帧时 DTS<PTS，若用视频首个 DTS
  // 当基线，视频会被多延迟 (firstAudioPts − firstVideoDts)，画面比音频晚、
  // B 帧越多越严重（实测真实样本晚 ~44ms）。因此取「音频首 PTS」与
  // 「视频最小 PTS」中的较小者作为全局呈现基线（与 ffmpeg 对齐）。
  final minVideoPts = vs.map((s) => s.pts).reduce((a, b) => a < b ? a : b);
  final globalMin = firstAudioPts < minVideoPts ? firstAudioPts : minVideoPts;
  // 已知边界：当 minVideoPts < firstAudioPts（视频早于音频）时，音频轨没有
  // 补偿延迟（本版不给音频写 edit list），音频会与视频同时起播而非按其真实
  // PTS 落后。真实点播样本一般是音频先起，故本版暂不处理该情形。
  final vDts = vs.map((s) => s.dts - globalMin).toList();
  final vPts = vs.map((s) => s.pts - globalMin).toList();
  final vDur = <int>[];
  for (int i = 0; i < vDts.length; i++) {
    if (i + 1 < vDts.length) {
      vDur.add(vDts[i + 1] - vDts[i]);
    } else {
      vDur.add(vDur.isNotEmpty ? vDur.last : 3000);
    }
  }
  final vTotalDur = vDur.fold<int>(0, (a, b) => a + b);
  final ctts = <int>[for (int i = 0; i < vPts.length; i++) vPts[i] - vDts[i]];

  const movieTimescale = 90000;
  const videoTimescale = 90000;
  final audioSampleRate = aac.sampleRate;
  final aTotalDur = aac.frames.length * 1024;

  // offsets: ftyp + mdat header(8) then body
  final ftyp = _box('ftyp', [
    ...'isom'.codeUnits,
    ..._u32(0x200),
    ...'isom'.codeUnits,
    ...'iso2'.codeUnits,
    ...'avc1'.codeUnits,
    ...'mp41'.codeUnits,
  ]);
  final mdatOffset = ftyp.length + 8; // mdat body 起点
  final vChunkOffset = mdatOffset;
  final aChunkOffset = mdatOffset + vChunkSize;

  // ---- stbl builders ----
  Uint8List stts(List<int> durs) {
    final entries = <List<int>>[];
    for (final d in durs) {
      if (entries.isNotEmpty && entries.last[1] == d) {
        entries.last[0]++;
      } else {
        entries.add([1, d]);
      }
    }
    final p = BytesBuilder(copy: false);
    p.add(_u32(entries.length));
    for (final e in entries) {
      p.add(_u32(e[0]));
      p.add(_u32(e[1]));
    }
    return _fullbox('stts', 0, 0, p.toBytes());
  }

  Uint8List cttsBox(List<int> offs) {
    final entries = <List<int>>[];
    for (final o in offs) {
      if (entries.isNotEmpty && entries.last[1] == o) {
        entries.last[0]++;
      } else {
        entries.add([1, o]);
      }
    }
    final p = BytesBuilder(copy: false);
    p.add(_u32(entries.length));
    for (final e in entries) {
      p.add(_u32(e[0]));
      p.add(_u32(e[1])); // 非负 -> version 0 可用
    }
    return _fullbox('ctts', 0, 0, p.toBytes());
  }

  Uint8List stszBox(List<int> sizes) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(0)); // sample_size=0 -> 表跟随
    p.add(_u32(sizes.length));
    for (final s in sizes) {
      p.add(_u32(s));
    }
    return _fullbox('stsz', 0, 0, p.toBytes());
  }

  Uint8List stscOneChunk(int count) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(1)); // 一个 entry
    p.add(_u32(1)); // first_chunk
    p.add(_u32(count)); // samples_per_chunk
    p.add(_u32(1)); // desc index
    return _fullbox('stsc', 0, 0, p.toBytes());
  }

  Uint8List stcoBox(int offset) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(1));
    p.add(_u32(offset));
    return _fullbox('stco', 0, 0, p.toBytes());
  }

  Uint8List stssBox(List<int> keyIdx) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(keyIdx.length));
    for (final k in keyIdx) {
      p.add(_u32(k));
    }
    return _fullbox('stss', 0, 0, p.toBytes());
  }

  Uint8List avc1() {
    final c = _box('avcC', buildAvcC(sps, pps));
    final p = BytesBuilder(copy: false);
    p.add(List.filled(6, 0)); // reserved
    p.add(_u16(1)); // data_ref_index
    p.add(List.filled(16, 0)); // pre-defined+reserved
    p.add(_u16(width));
    p.add(_u16(height));
    p.add(_u32(0x00480000)); // hres
    p.add(_u32(0x00480000)); // vres
    p.add(_u32(0)); // reserved
    p.add(_u16(1)); // frame_count
    p.add(List.filled(32, 0)); // compressorname
    p.add(_u16(0x18)); // depth
    p.add([0xff, 0xff]); // pre-defined -1
    p.add(c);
    return _box('avc1', p.toBytes());
  }

  Uint8List esds() {
    final asc = <int>[
      ((aac.objectType << 3) | (aac.freqIndex >> 1)) & 0xff,
      (((aac.freqIndex & 1) << 7) | (aac.channels << 3)) & 0xff,
    ];
    List<int> descr(int tag, List<int> body) => [tag, body.length, ...body];
    final decSpecific = descr(0x05, asc);
    final decConfig = descr(0x04, [
      0x40, // MPEG-4 Audio
      0x15, // stream type audio(0x05<<2)|0x01
      0, 0, 0, // bufferSizeDB
      ..._u32(0), // maxBitrate
      ..._u32(0), // avgBitrate
      ...decSpecific,
    ]);
    final slConfig = descr(0x06, [0x02]);
    final es = descr(0x03, [
      0, 0, // ES_ID
      0, // flags
      ...decConfig,
      ...slConfig,
    ]);
    return _fullbox('esds', 0, 0, es);
  }

  Uint8List mp4a() {
    final p = BytesBuilder(copy: false);
    p.add(List.filled(6, 0));
    p.add(_u16(1)); // data_ref_index
    p.add(List.filled(8, 0)); // reserved
    p.add(_u16(aac.channels)); // channelcount
    p.add(_u16(16)); // samplesize
    p.add(_u32(0)); // pre-defined+reserved
    p.add(_u16(audioSampleRate)); // samplerate (upper 16 of 16.16)
    p.add(_u16(0));
    p.add(esds());
    return _box('mp4a', p.toBytes());
  }

  Uint8List stsd(Uint8List entry) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(1));
    p.add(entry);
    return _fullbox('stsd', 0, 0, p.toBytes());
  }

  // video stbl
  final keyIdx = <int>[];
  for (int i = 0; i < vs.length; i++) {
    if (vs[i].keyframe) keyIdx.add(i + 1);
  }
  final vStbl = _box('stbl', [
    ...stsd(avc1()),
    ...stts(vDur),
    ...cttsBox(ctts),
    ...stssBox(keyIdx),
    ...stscOneChunk(vs.length),
    ...stszBox(vSizes),
    ...stcoBox(vChunkOffset),
  ]);
  final aStbl = _box('stbl', [
    ...stsd(mp4a()),
    ...stts(List.filled(aac.frames.length, 1024)),
    ...stscOneChunk(aac.frames.length),
    ...stszBox(aSizes),
    ...stcoBox(aChunkOffset),
  ]);

  Uint8List mdhd(int timescale, int duration) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(0)); // creation
    p.add(_u32(0)); // modification
    p.add(_u32(timescale));
    p.add(_u32(duration));
    p.add([0x55, 0xc4]); // language 'und'
    p.add(_u16(0));
    return _fullbox('mdhd', 0, 0, p.toBytes());
  }

  Uint8List hdlr(String handler, String name) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(0)); // pre_defined
    p.add(handler.codeUnits);
    p.add(List.filled(12, 0)); // reserved
    p.add(name.codeUnits);
    p.add([0]);
    return _fullbox('hdlr', 0, 0, p.toBytes());
  }

  final vmhd = _fullbox('vmhd', 0, 1, [0, 0, 0, 0, 0, 0, 0, 0]);
  final smhd = _fullbox('smhd', 0, 0, [0, 0, 0, 0]);
  final dref = _fullbox('dref', 0, 0, [..._u32(1), ..._fullbox('url ', 0, 1, [])]);
  final dinf = _box('dinf', dref);

  Uint8List minf(Uint8List mh, Uint8List stbl) =>
      _box('minf', [...mh, ...dinf, ...stbl]);

  final vMdia = _box('mdia', [
    ...mdhd(videoTimescale, vTotalDur),
    ...hdlr('vide', 'VideoHandler'),
    ...minf(vmhd, vStbl),
  ]);
  final aMdia = _box('mdia', [
    ...mdhd(audioSampleRate, aTotalDur),
    ...hdlr('soun', 'SoundHandler'),
    ...minf(smhd, aStbl),
  ]);

  Uint8List tkhdVideo(int trackId, int w, int h, int durInMovie) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(0)); // creation
    p.add(_u32(0)); // modification
    p.add(_u32(trackId));
    p.add(_u32(0)); // reserved
    p.add(_u32(durInMovie));
    p.add(List.filled(8, 0)); // reserved
    p.add(_u16(0)); // layer
    p.add(_u16(0)); // alt group
    p.add(_u16(0)); // volume（视频轨 0）
    p.add(_u16(0));
    final m = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
    for (final v in m) {
      p.add(_u32(v));
    }
    p.add(_u32(w << 16));
    p.add(_u32(h << 16));
    return _fullbox('tkhd', 0, 0x7, p.toBytes());
  }

  // Edit list（ffmpeg 对含 B 帧内容的方案）：
  //  - 空编辑（长度 dEmpty，movie timescale）把视频延迟到与音频对齐的呈现时刻
  //    （此样本音频先开始），保证 A/V 同步。
  //  - media 编辑 media_time = minComposition，跳过初始重排/composition 延迟，
  //    从首帧干净起播；若写 media_time=0 会指向 [0,minComposition) 空洞，ffmpeg 会丢掉前几帧。
  // movie timescale == video timescale(90000)，无需换算。
  final minPts = vPts.reduce((a, b) => a < b ? a : b); // 首个呈现 PTS
  final mediaStart = minPts - vDts[0]; // media 时间线里的最小 composition
  final dEmpty = minPts; // 相对全局（音频）起点的呈现偏移
  final vTrackMovieDur = dEmpty + vTotalDur;

  Uint8List edts() {
    final p = BytesBuilder(copy: false);
    p.add(_u32(2));
    p.add(_u32(dEmpty));
    p.add(_u32(0xffffffff)); // 空编辑
    p.add(_u32(0x00010000));
    p.add(_u32(vTotalDur));
    p.add(_u32(mediaStart));
    p.add(_u32(0x00010000));
    return _box('edts', _fullbox('elst', 0, 0, p.toBytes()));
  }

  final vTrak = _box('trak', [
    ...tkhdVideo(1, width, height, vTrackMovieDur),
    ...edts(),
    ...vMdia,
  ]);

  Uint8List tkhdAudio(int trackId, int durInMovie) {
    final p = BytesBuilder(copy: false);
    p.add(_u32(0));
    p.add(_u32(0));
    p.add(_u32(trackId));
    p.add(_u32(0));
    p.add(_u32(durInMovie));
    p.add(List.filled(8, 0));
    p.add(_u16(0));
    p.add(_u16(0));
    p.add(_u16(0x0100)); // volume
    p.add(_u16(0));
    final m = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
    for (final v in m) {
      p.add(_u32(v));
    }
    p.add(_u32(0));
    p.add(_u32(0));
    return _fullbox('tkhd', 0, 0x7, p.toBytes());
  }

  final aTrak = _box('trak', [
    ...tkhdAudio(2, aTotalDur),
    ...aMdia,
  ]);

  Uint8List mvhd() {
    final p = BytesBuilder(copy: false);
    p.add(_u32(0));
    p.add(_u32(0));
    p.add(_u32(movieTimescale));
    final aMovieDur = (aTotalDur * movieTimescale) ~/ audioSampleRate;
    p.add(_u32(vTrackMovieDur > aMovieDur ? vTrackMovieDur : aMovieDur));
    p.add(_u32(0x00010000)); // rate
    p.add(_u16(0x0100)); // volume
    p.add(_u16(0));
    p.add(_u32(0));
    p.add(_u32(0));
    final m = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000];
    for (final v in m) {
      p.add(_u32(v));
    }
    p.add(List.filled(24, 0)); // pre_defined
    p.add(_u32(3)); // next_track_id
    return _fullbox('mvhd', 0, 0, p.toBytes());
  }

  final moov = _box('moov', [...mvhd(), ...vTrak, ...aTrak]);

  // ---- 组装文件 ----
  final out = BytesBuilder(copy: false);
  out.add(ftyp);
  final mdatHdr = BytesBuilder(copy: false);
  _wU32(mdatHdr, 8 + mdat.length);
  mdatHdr.add('mdat'.codeUnits);
  out.add(mdatHdr.toBytes());
  out.add(mdat);
  out.add(moov);

  return Mp4BuildResult(
    bytes: out.toBytes(),
    mdatSize: mdat.length,
    moovSize: moov.length,
    videoTimescale: videoTimescale,
    firstPts: vs.first.pts,
    firstDts: vs.first.dts,
    emptyEditDur: dEmpty,
    mediaStart: mediaStart,
    videoTotalDur: vTotalDur,
    firstCtts: ctts.take(6).toList(),
  );
}
