import 'dart:typed_data';

/// AAC 采样率索引表（ADTS sampling_frequency_index）。
const List<int> aacFreqTable = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, //
  16000, 12000, 11025, 8000, 7350,
];

/// 从一串 ADTS 数据中解析出的 AAC 信息。
class AacInfo {
  final List<Uint8List> frames; // 每帧裸 AAC（去掉 ADTS 头），一帧 = 1024 采样
  final int objectType; // AOT（LC=2）
  final int freqIndex; // sampling_frequency_index
  final int channels; // 声道数
  int get sampleRate => aacFreqTable[freqIndex];

  const AacInfo(this.frames, this.objectType, this.freqIndex, this.channels);
}

/// 逐个 PES payload 解析 ADTS 帧。传入的 [payloads] 是音频 PES 的裸数据序列。
///
/// ADTS 帧可能跨 PES 边界：payload 末尾不完整的帧（含不足 7 字节的半个帧头）
/// 会缓存并与下一段拼接后继续解析，不丢帧。
AacInfo? parseAdts(Iterable<Uint8List> payloads) {
  final frames = <Uint8List>[];
  int? objType, freqIdx, chan;
  Uint8List carry = Uint8List(0);
  for (final p in payloads) {
    Uint8List d;
    if (carry.isEmpty) {
      d = p;
    } else {
      d = Uint8List(carry.length + p.length)
        ..setAll(0, carry)
        ..setAll(carry.length, p);
    }
    int i = 0;
    while (i < d.length) {
      if (i + 2 > d.length) break; // 末尾单字节，可能是 syncword 前半
      if (d[i] != 0xff || (d[i + 1] & 0xf0) != 0xf0) {
        i++;
        continue;
      }
      if (i + 7 > d.length) break; // 帧头不完整，留待下一段
      final protAbsent = d[i + 1] & 0x1;
      final profile = (d[i + 2] >> 6) & 0x3; // 0=Main,1=LC,...
      final fIdx = (d[i + 2] >> 2) & 0xf;
      final ch = ((d[i + 2] & 0x1) << 2) | ((d[i + 3] >> 6) & 0x3);
      final frameLen =
          ((d[i + 3] & 0x3) << 11) | (d[i + 4] << 3) | ((d[i + 5] >> 5) & 0x7);
      if (frameLen < 7) {
        i++; // 假 syncword
        continue;
      }
      if (i + frameLen > d.length) break; // 帧体不完整，留待下一段
      final hdr = protAbsent == 1 ? 7 : 9;
      objType ??= profile + 1; // AOT = profile+1（LC->2）
      freqIdx ??= fIdx;
      chan ??= ch;
      frames.add(Uint8List.sublistView(d, i + hdr, i + frameLen));
      i += frameLen;
    }
    carry = i < d.length ? d.sublist(i) : Uint8List(0);
  }
  if (frames.isEmpty || objType == null || freqIdx == null || chan == null) {
    return null;
  }
  if (freqIdx >= aacFreqTable.length) return null;
  return AacInfo(frames, objType, freqIdx, chan);
}
