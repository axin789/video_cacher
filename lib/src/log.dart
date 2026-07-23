import 'dart:developer' as dev;

/// 下载链路（引擎/刷新器/HLS/MP4）的结构化日志开关。
/// transmuxer 的日志同样受本开关控制。
class VideoCacherLog {
  VideoCacherLog._();

  /// 置 false 可静默全部下载链路日志。默认开启，release 构建建议关闭。
  static bool verbose = true;

  /// 打一条调试日志（logger 名为 `video_cacher.<area>`）。受 [verbose] 控制。
  static void d(String area, String message) {
    if (verbose) dev.log(message, name: 'video_cacher.$area');
  }
}
