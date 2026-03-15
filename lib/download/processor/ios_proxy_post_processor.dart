import 'package:ffmpeg_remux/download/download_library.dart';

import 'post_processor.dart';

class IosProxyPostProcessor implements PostProcessor {
  @override
  Future<PostProcessResult> run({
    required String inM3u8,
    required String outMp4,
    required M3u8Task task,
    void Function(int bytes)? onBytes,
  }) async {
    return PostProcessResult(ret: 0, playableUrl: inM3u8);
  }

  @override
  Future<void> cleanup({
    required M3u8Task task,
    required String inM3u8,
    required String? outMp4,
    required bool success,
  }) async {
    // iOS 通常不清理这些文件，因为还要走本地代理播放
  }

  @override
  void cancel(M3u8Task task) {}
}
