import 'dart:math' as math;

/// 构建一个引用本地分片文件（绝对路径作为 URI）的本地媒体播放列表。
///
/// EXTINF 用名义值、且不写 EXT-X-KEY（分片已解密）。ffmpeg 从 TS 包的 PTS
/// 读取真实时间戳，因此 EXTINF 只是占位、不影响正确性。纯函数，无 I/O。
String buildLocalM3u8(
  List<String> segmentFiles, {
  double nominalDurationSec = 10.0,
}) {
  final targetDuration = math.max(1, nominalDurationSec.ceil());
  final buffer = StringBuffer()
    ..write('#EXTM3U\n')
    ..write('#EXT-X-VERSION:3\n')
    ..write('#EXT-X-TARGETDURATION:$targetDuration\n')
    ..write('#EXT-X-MEDIA-SEQUENCE:0\n');
  for (final path in segmentFiles) {
    buffer
      ..write('#EXTINF:$nominalDurationSec,\n')
      ..write('$path\n');
  }
  buffer.write('#EXT-X-ENDLIST\n');
  return buffer.toString();
}
