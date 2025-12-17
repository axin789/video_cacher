import '../download_library.dart';

abstract class PostProcessor {
  Future<PostProcessResult> run({
    required String inM3u8,
    required String outMp4,
    required M3u8Task task,
    void Function(int bytes)? onBytes,
  });

  Future<void> cleanup({
    required M3u8Task task,
    required String inM3u8,
    required String? outMp4,
    required bool success,
  });

  /// - Android：取消 FFmpeg remux
  /// - iOS：一般什么都不做
  void cancel(M3u8Task task) {
    // default: no-op
  }
}

class PostProcessResult {
  final int ret; // 0 ok
  final String? outMp4;
  final String? playableUrl; // iOS proxy 或 local m3u8
  PostProcessResult({required this.ret, this.outMp4, this.playableUrl});
}