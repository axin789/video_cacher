import 'dart:typed_data';

/// H.264 NAL 类型（本项目关心的）。
class NalType {
  static const int idr = 5;
  static const int sps = 7;
  static const int pps = 8;
}

/// 把 Annex-B 字节流拆成 NAL 单元（不含起始码）。
List<Uint8List> splitNals(Uint8List d) {
  final nals = <Uint8List>[];
  final n = d.length;
  int scLen = 0;
  int p = 0;
  while (p + 3 <= n) {
    if (d[p] == 0 && d[p + 1] == 0 && d[p + 2] == 1) {
      scLen = 3;
      break;
    }
    if (p + 4 <= n &&
        d[p] == 0 &&
        d[p + 1] == 0 &&
        d[p + 2] == 0 &&
        d[p + 3] == 1) {
      scLen = 4;
      break;
    }
    p++;
  }
  if (scLen == 0) return nals;
  int start = p + scLen;
  int i = start;
  while (i + 3 <= n) {
    if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
      nals.add(Uint8List.sublistView(d, start, i));
      start = i + 3;
      i = start;
      continue;
    }
    if (i + 4 <= n &&
        d[i] == 0 &&
        d[i + 1] == 0 &&
        d[i + 2] == 0 &&
        d[i + 3] == 1) {
      nals.add(Uint8List.sublistView(d, start, i));
      start = i + 4;
      i = start;
      continue;
    }
    i++;
  }
  nals.add(Uint8List.sublistView(d, start, n));
  return nals;
}

/// 从 SPS/PPS 生成 avcC 配置盒的 payload（不含 box 头）。
Uint8List buildAvcC(Uint8List sps, Uint8List pps) {
  final b = BytesBuilder(copy: false);
  b.add([1, sps[1], sps[2], sps[3], 0xff, 0xe1]);
  b.add([(sps.length >> 8) & 0xff, sps.length & 0xff]);
  b.add(sps);
  b.add([1]);
  b.add([(pps.length >> 8) & 0xff, pps.length & 0xff]);
  b.add(pps);
  return b.toBytes();
}

/// SPS 解出的画面尺寸。
class SpsDimensions {
  final int width;
  final int height;
  const SpsDimensions(this.width, this.height);
}

/// 从 SPS（不含起始码，含 NAL 头字节）解析显示宽高（考虑 cropping）。
SpsDimensions parseSpsDimensions(Uint8List sps) {
  // 去除 emulation prevention 字节（00 00 03 -> 00 00）。
  final rbsp = _stripEmulation(sps, 1); // 跳过 NAL 头字节
  final r = _BitReader(rbsp);
  final profileIdc = r.u(8);
  r.u(8); // constraint flags + reserved
  r.u(8); // level_idc
  r.ue(); // seq_parameter_set_id

  int chromaFormatIdc = 1; // 默认 4:2:0
  if (profileIdc == 100 ||
      profileIdc == 110 ||
      profileIdc == 122 ||
      profileIdc == 244 ||
      profileIdc == 44 ||
      profileIdc == 83 ||
      profileIdc == 86 ||
      profileIdc == 118 ||
      profileIdc == 128 ||
      profileIdc == 138 ||
      profileIdc == 139 ||
      profileIdc == 134 ||
      profileIdc == 135) {
    chromaFormatIdc = r.ue();
    if (chromaFormatIdc == 3) r.u(1); // separate_colour_plane_flag
    r.ue(); // bit_depth_luma_minus8
    r.ue(); // bit_depth_chroma_minus8
    r.u(1); // qpprime_y_zero_transform_bypass_flag
    final scalingPresent = r.u(1);
    if (scalingPresent == 1) {
      final count = chromaFormatIdc != 3 ? 8 : 12;
      for (int i = 0; i < count; i++) {
        final present = r.u(1);
        if (present == 1) _skipScalingList(r, i < 6 ? 16 : 64);
      }
    }
  }

  r.ue(); // log2_max_frame_num_minus4
  final picOrderCntType = r.ue();
  if (picOrderCntType == 0) {
    r.ue(); // log2_max_pic_order_cnt_lsb_minus4
  } else if (picOrderCntType == 1) {
    r.u(1); // delta_pic_order_always_zero_flag
    r.se(); // offset_for_non_ref_pic
    r.se(); // offset_for_top_to_bottom_field
    final n = r.ue();
    for (int i = 0; i < n; i++) {
      r.se();
    }
  }
  r.ue(); // max_num_ref_frames
  r.u(1); // gaps_in_frame_num_value_allowed_flag
  final picWidthInMbsMinus1 = r.ue();
  final picHeightInMapUnitsMinus1 = r.ue();
  final frameMbsOnlyFlag = r.u(1);
  if (frameMbsOnlyFlag == 0) r.u(1); // mb_adaptive_frame_field_flag
  r.u(1); // direct_8x8_inference_flag

  int cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  final frameCropping = r.u(1);
  if (frameCropping == 1) {
    cropLeft = r.ue();
    cropRight = r.ue();
    cropTop = r.ue();
    cropBottom = r.ue();
  }

  final width0 = (picWidthInMbsMinus1 + 1) * 16;
  final height0 = (2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1) * 16;

  // cropping 单位：4:2:0/4:2:2 时 SubWidthC=2；4:4:4/单色时=1
  int subWidthC, subHeightC;
  switch (chromaFormatIdc) {
    case 0: // 单色
      subWidthC = 1;
      subHeightC = 1;
      break;
    case 3: // 4:4:4
      subWidthC = 1;
      subHeightC = 1;
      break;
    case 2: // 4:2:2
      subWidthC = 2;
      subHeightC = 1;
      break;
    default: // 4:2:0
      subWidthC = 2;
      subHeightC = 2;
  }
  final cropUnitX = chromaFormatIdc == 0 ? 1 : subWidthC;
  final cropUnitY =
      (chromaFormatIdc == 0 ? 1 : subHeightC) * (2 - frameMbsOnlyFlag);

  final width = width0 - (cropLeft + cropRight) * cropUnitX;
  final height = height0 - (cropTop + cropBottom) * cropUnitY;
  return SpsDimensions(width, height);
}

Uint8List _stripEmulation(Uint8List d, int start) {
  final out = BytesBuilder(copy: false);
  int zeros = 0;
  for (int i = start; i < d.length; i++) {
    final b = d[i];
    if (zeros >= 2 && b == 0x03) {
      zeros = 0;
      continue; // 丢弃 emulation_prevention_three_byte
    }
    out.addByte(b);
    if (b == 0) {
      zeros++;
    } else {
      zeros = 0;
    }
  }
  return out.toBytes();
}

void _skipScalingList(_BitReader r, int size) {
  int lastScale = 8;
  int nextScale = 8;
  for (int j = 0; j < size; j++) {
    if (nextScale != 0) {
      final delta = r.se();
      nextScale = (lastScale + delta + 256) % 256;
    }
    lastScale = nextScale == 0 ? lastScale : nextScale;
  }
}

class _BitReader {
  final Uint8List d;
  int _byte = 0;
  int _bit = 0;
  _BitReader(this.d);

  int u(int n) {
    int v = 0;
    for (int i = 0; i < n; i++) {
      v = (v << 1) | _readBit();
    }
    return v;
  }

  int _readBit() {
    if (_byte >= d.length) return 0;
    final b = (d[_byte] >> (7 - _bit)) & 1;
    _bit++;
    if (_bit == 8) {
      _bit = 0;
      _byte++;
    }
    return b;
  }

  int ue() {
    int zeros = 0;
    while (_readBit() == 0 && _byte < d.length) {
      zeros++;
      if (zeros > 31) break;
    }
    int v = 0;
    for (int i = 0; i < zeros; i++) {
      v = (v << 1) | _readBit();
    }
    return (1 << zeros) - 1 + v;
  }

  int se() {
    final k = ue();
    final sign = (k & 1) == 1 ? 1 : -1;
    return sign * ((k + 1) >> 1);
  }
}
