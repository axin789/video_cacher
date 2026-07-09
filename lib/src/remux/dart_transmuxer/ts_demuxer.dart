import 'dart:typed_data';

/// MPEG-TS stream_type 常量（仅列出本项目关心的）。
class TsStreamType {
  static const int h264 = 0x1b;
  static const int hevc = 0x24;
  static const int aacAdts = 0x0f;

  static bool isVideo(int t) =>
      t == h264 || t == hevc || t == 0x01 || t == 0x02 || t == 0x21;
  static bool isAudio(int t) =>
      t == aacAdts || t == 0x11 || t == 0x03 || t == 0x04 || t == 0x81;
}

const int _tsPkt = 188;

/// 一个 PES 单元：一段带 PTS/DTS 的基本流数据。
class PesUnit {
  int? pts;
  int? dts;
  final BytesBuilder data = BytesBuilder(copy: false);
}

/// 单条基本流（video 或 audio）的 PES 重组。
class ElementaryStream {
  final int pid;
  final int streamType;
  final List<PesUnit> units = [];
  PesUnit? _cur;

  ElementaryStream(this.pid, this.streamType);

  void onPacket(Uint8List payload, bool pusi) {
    if (pusi) {
      _flush();
      _cur = PesUnit();
    }
    if (_cur != null) _cur!.data.add(payload);
  }

  void _flush() {
    if (_cur != null) {
      _parsePes(_cur!);
      units.add(_cur!);
    }
    _cur = null;
  }

  void finish() => _flush();
}

void _parsePes(PesUnit u) {
  final b = u.data.toBytes();
  // packet_start_code_prefix 00 00 01
  if (b.length < 9 || b[0] != 0 || b[1] != 0 || b[2] != 1) {
    _rewriteData(u, b, 0);
    return;
  }
  final ptsDtsFlags = (b[7] >> 6) & 0x3;
  final headerLen = b[8];
  int off = 9;
  if (ptsDtsFlags == 0x2) {
    u.pts = _readTs(b, off);
    u.dts = u.pts;
  } else if (ptsDtsFlags == 0x3) {
    u.pts = _readTs(b, off);
    u.dts = _readTs(b, off + 5);
  }
  final payloadStart = 9 + headerLen;
  _rewriteData(u, b, payloadStart);
}

void _rewriteData(PesUnit u, Uint8List b, int start) {
  final bb = BytesBuilder(copy: false);
  if (start < b.length) bb.add(Uint8List.sublistView(b, start));
  u.data.clear();
  u.data.add(bb.toBytes());
}

int _readTs(Uint8List b, int o) {
  return (((b[o] >> 1) & 0x07) << 30) |
      (b[o + 1] << 22) |
      (((b[o + 2] >> 1) & 0x7f) << 15) |
      (b[o + 3] << 7) |
      ((b[o + 4] >> 1) & 0x7f);
}

/// 有状态的 TS 解复用器：可分片喂入（[feed]）、结束时 [finish]。
///
/// 解析 PAT→PMT，识别第一路 video PID + 第一路 audio PID 及其 stream_type，
/// 重组各自的 PES，抽取 PTS/DTS。分片按 188 字节 TS 包对齐，跨 feed 的残余
/// 字节会缓存到下次。
class TsDemuxer {
  int? pmtPid;
  ElementaryStream? video;
  ElementaryStream? audio;

  final BytesBuilder _leftover = BytesBuilder(copy: false);

  int? get videoStreamType => video?.streamType;
  int? get audioStreamType => audio?.streamType;

  void feed(Uint8List chunk) {
    Uint8List data;
    if (_leftover.length == 0) {
      data = chunk;
    } else {
      _leftover.add(chunk);
      data = _leftover.toBytes();
      _leftover.clear();
    }
    int i = 0;
    final n = data.length;
    while (i + _tsPkt <= n) {
      if (data[i] != 0x47) {
        // 重新对齐到下一个同步字节
        int j = i + 1;
        while (j < n && data[j] != 0x47) {
          j++;
        }
        i = j;
        continue;
      }
      _packet(data, i);
      i += _tsPkt;
    }
    // 保留未处理完整包的尾部
    if (i < n) _leftover.add(Uint8List.sublistView(data, i));
  }

  void _packet(Uint8List data, int i) {
    final b1 = data[i + 1];
    final b2 = data[i + 2];
    final b3 = data[i + 3];
    final pusi = (b1 & 0x40) != 0;
    final pid = ((b1 & 0x1f) << 8) | b2;
    final afc = (b3 >> 4) & 0x3;
    int off = i + 4;
    if (afc == 0x2 || afc == 0x3) {
      final afLen = data[off];
      off += 1 + afLen;
    }
    if (afc == 0x1 || afc == 0x3) {
      if (off > i + _tsPkt) return;
      final payload = Uint8List.sublistView(data, off, i + _tsPkt);
      _dispatch(pid, pusi, payload);
    }
  }

  void _dispatch(int pid, bool pusi, Uint8List payload) {
    if (pid == 0) {
      _parsePat(payload, pusi);
    } else if (pmtPid != null && pid == pmtPid) {
      _parsePmt(payload, pusi);
    } else if (video != null && pid == video!.pid) {
      video!.onPacket(payload, pusi);
    } else if (audio != null && pid == audio!.pid) {
      audio!.onPacket(payload, pusi);
    }
  }

  void _parsePat(Uint8List p, bool pusi) {
    if (pmtPid != null) return;
    int o = 0;
    if (pusi) o += 1 + p[0]; // pointer_field
    final sectionLen = ((p[o + 1] & 0x0f) << 8) | p[o + 2];
    final end = o + 3 + sectionLen - 4; // 去掉 CRC
    int idx = o + 8; // 跳到 program 循环
    while (idx + 4 <= end) {
      final prog = (p[idx] << 8) | p[idx + 1];
      final pid = ((p[idx + 2] & 0x1f) << 8) | p[idx + 3];
      if (prog != 0) {
        pmtPid = pid;
        break;
      }
      idx += 4;
    }
  }

  void _parsePmt(Uint8List p, bool pusi) {
    if (video != null || audio != null) return;
    int o = 0;
    if (pusi) o += 1 + p[0];
    final sectionLen = ((p[o + 1] & 0x0f) << 8) | p[o + 2];
    final end = o + 3 + sectionLen - 4;
    final programInfoLen = ((p[o + 10] & 0x0f) << 8) | p[o + 11];
    int idx = o + 12 + programInfoLen;
    while (idx + 5 <= end) {
      final streamType = p[idx];
      final ePid = ((p[idx + 1] & 0x1f) << 8) | p[idx + 2];
      final esInfoLen = ((p[idx + 3] & 0x0f) << 8) | p[idx + 4];
      if (TsStreamType.isVideo(streamType) && video == null) {
        video = ElementaryStream(ePid, streamType);
      } else if (TsStreamType.isAudio(streamType) && audio == null) {
        audio = ElementaryStream(ePid, streamType);
      }
      idx += 5 + esInfoLen;
    }
  }

  void finish() {
    video?.finish();
    audio?.finish();
  }
}
