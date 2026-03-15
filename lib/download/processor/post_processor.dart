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
  /// - iOS：通常无需额外处理
  void cancel(M3u8Task task) {
    // 默认空实现
  }
}

class PostProcessResult {
  final int ret; // 0 表示成功
  final String? outMp4;
  final String? playableUrl; // iOS 代理地址或本地 m3u8 地址
  PostProcessResult({required this.ret, this.outMp4, this.playableUrl});
}
