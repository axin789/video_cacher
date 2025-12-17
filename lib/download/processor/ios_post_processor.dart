import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

import '../../ffmpeg_remux_ios.dart';
import '../model/m3u8_models.dart';
import 'post_processor.dart';

class IosPostProcessor  implements PostProcessor  {

  @override
  Future<PostProcessResult> run({
    required String inM3u8,
    required String outMp4,
    required M3u8Task task,
    void Function(int bytes)? onBytes,
  }) async {
    if (!Platform.isIOS) {
      return PostProcessResult(ret: -1, playableUrl: inM3u8);
    }

    StreamSubscription? sub;
    final completer = Completer<PostProcessResult>();

    sub = FfmpegRemuxIos.eventStream.listen((e) async {
      if (e.taskId != task.taskId) return;

      // 伪 bytes：用于 UI
      onBytes?.call((e.progress * 1000000).toInt());

      if (!e.isDone) return;

      await sub?.cancel();

      if (e.isSuccess) {
        completer.complete(PostProcessResult(ret: 0, outMp4: e.outPath ?? outMp4, playableUrl: e.outPath ?? outMp4));
      } else {
        completer.complete(PostProcessResult(ret: e.ret ?? -1, playableUrl: inM3u8));
      }
    });

    // 发起异步任务（立刻返回，不堵 UI）
    await FfmpegRemuxIos.startRemux(
      taskId: task.taskId,
      inM3u8: inM3u8,
      outPath: outMp4,
    );

    return completer.future;
  }


  @override
  void cancel(M3u8Task task) {
    FfmpegRemuxIos.cancelRemux(taskId: task.taskId);
  }

  @override
  Future<void> cleanup({required M3u8Task task, required String inM3u8, required String? outMp4, required bool success}) async{
    final dir = Directory(task.dir);
    if (!await dir.exists()) return;

    await for (final e in dir.list(recursive: false)) {
      final name = p.basename(e.path);
      if (outMp4 != null && e.path == outMp4) continue;
      if (name.endsWith('.mp4')) continue;
      try { await e.delete(recursive: true); } catch (_) {}
    }
  }
}