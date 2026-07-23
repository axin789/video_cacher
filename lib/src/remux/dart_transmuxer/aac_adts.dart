import 'dart:typed_data';

/// AAC 采样率索引表（ADTS sampling_frequency_index）。
const List<int> aacFreqTable = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, //
  16000, 12000, 11025, 8000, 7350,
];

/// 一条 AAC 音轨的样本表：帧字节已流式写出（ES 临时文件），这里只留
/// 每帧大小与首帧头部参数（构建 mp4 的 stsz/esds 所需）。
class AacTrack {
  final List<int> frameSizes; // 每帧裸 AAC 字节数（去 ADTS 头），一帧 = 1024 采样
  final int objectType; // AOT（LC=2）
  final int freqIndex; // sampling_frequency_index
  final int channels; // 声道数
  int get sampleRate => aacFreqTable[freqIndex];

  const AacTrack(this.frameSizes, this.objectType, this.freqIndex, this.channels);
}

/// 流式 ADTS 解析器：逐段喂入音频 PES payload（[feed]），完整帧即时返回，
/// 不整装累积——GB 级输入驻留内存的只有 [int] 帧大小表与跨段残余字节。
///
/// ADTS 帧可能跨 PES 边界：payload 末尾不完整的帧（含不足 7 字节的半个帧头）
/// 会缓存并与下一段拼接后继续解析，不丢帧。头部参数取首个完整帧。
class AdtsStream {
  int? _objectType, _freqIndex, _channels;
  final List<int> _frameSizes = [];
  Uint8List _carry = _empty;

  static final Uint8List _empty = Uint8List(0);

  /// 喂入一段 PES payload，返回其中解析出的完整帧（裸 AAC，去 ADTS 头）。
  /// 返回的帧是喂入缓冲上的视图，调用方应在下次 [feed] 前消费完。
  List<Uint8List> feed(Uint8List payload) {
    final frames = <Uint8List>[];
    Uint8List d;
    if (_carry.isEmpty) {
      d = payload;
    } else {
      d = Uint8List(_carry.length + payload.length)
        ..setAll(0, _carry)
        ..setAll(_carry.length, payload);
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
      _objectType ??= profile + 1; // AOT = profile+1（LC->2）
      _freqIndex ??= fIdx;
      _channels ??= ch;
      final frame = Uint8List.sublistView(d, i + hdr, i + frameLen);
      _frameSizes.add(frame.length);
      frames.add(frame);
      i += frameLen;
    }
    // 残余必须拷贝（sublist）而非取视图，否则会把整段 payload 钉在内存里。
    _carry = i < d.length ? d.sublist(i) : _empty;
    return frames;
  }

  /// 已解析出的音轨样本表；无可解码帧或采样率索引非法时为 null。
  AacTrack? get track {
    final obj = _objectType, fIdx = _freqIndex, ch = _channels;
    if (_frameSizes.isEmpty || obj == null || fIdx == null || ch == null) {
      return null;
    }
    if (fIdx >= aacFreqTable.length) return null;
    return AacTrack(_frameSizes, obj, fIdx, ch);
  }
}
