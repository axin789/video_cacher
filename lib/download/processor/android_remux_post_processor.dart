import 'dart:io';

import 'package:ffmpeg_remux/download/download_library.dart';
import 'package:path/path.dart' as p;

import '../../ffmpeg_remux.dart';
import 'post_processor.dart';

class AndroidRemuxPostProcessor implements PostProcessor {
  @override
  Future<PostProcessResult> run({
    required String inM3u8,
    required String outMp4,
    required M3u8Task task,
    void Function(int bytes)? onBytes,
  }) async {
    // 监听 remux bytes
    final sub = FfmpegRemux.progressStream.listen((p) {
      if (p.output == outMp4 && p.state == 'running') {
        onBytes?.call(p.bytes);
      }
    });

    try {
      final res = await FfmpegRemux.remux(input: inM3u8, output: outMp4);
      return PostProcessResult(ret: res.ret, outMp4: res.output);
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<void> cleanup({
    required M3u8Task task,
    required String inM3u8,
    required String? outMp4,
    required bool success,
  }) async {
    if (!success) return;

    // 成功后：删除 ts/key/local.m3u8，仅保留 mp4
    // 也可以只删 task.dir 里除了 mp4 的文件
    final dir = Directory(task.dir);
    if (!await dir.exists()) return;

    await for (final e in dir.list(recursive: false)) {
      final name = p.basename(e.path);
      if (outMp4 != null && e.path == outMp4) continue;
      if (name.endsWith('.mp4')) continue;
      try { await e.delete(recursive: true); } catch (_) {}
    }
  }

  @override
  void cancel(M3u8Task task) {
    FfmpegRemux.cancel();
  }
}