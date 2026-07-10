import 'dart:developer' as dev;

/// 下载链路（引擎/刷新器/HLS/MP4）的结构化日志开关。
/// transmuxer 的日志另由 `DartTransmuxer.verbose` 控制。
class FfmpegRemuxLog {
  FfmpegRemuxLog._();

  /// 置 false 可静默全部下载链路日志。
  static bool verbose = true;

  static void d(String area, String message) {
    if (verbose) dev.log(message, name: 'ffmpeg_remux.$area');
  }
}
