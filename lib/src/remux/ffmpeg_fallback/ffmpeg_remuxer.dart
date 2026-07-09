import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_remux/ffmpeg_remux.dart' as android_native;
import 'package:ffmpeg_remux/ffmpeg_remux_ios.dart' as ios_native;
import 'package:path/path.dart' as p;

import '../local_m3u8.dart';
import '../remuxer.dart';

/// 复用现有 native remux 的兜底实现：写 local.m3u8 指向已解密分片，
/// 交给 Android/iOS 的 FFmpeg 转封装（-c copy，不转码）。
///
/// 纯 Dart transmuxer 就绪后作为默认实现被替换，本类作为永久安全网保留。
class FfmpegRemuxer implements Remuxer {
  @override
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles,
    required String outMp4,
    required String dir,
    void Function(int bytes)? onProgress,
  }) async {
    final localM3u8Path = p.join(dir, 'local.m3u8');
    await File(localM3u8Path).writeAsString(buildLocalM3u8(segmentFiles));

    if (Platform.isAndroid) {
      return _remuxAndroid(localM3u8Path, outMp4, onProgress);
    }
    if (Platform.isIOS) {
      return _remuxIos(taskId, localM3u8Path, outMp4, onProgress);
    }
    return const RemuxResult(ok: false, error: 'unsupported platform');
  }

  Future<RemuxResult> _remuxAndroid(
    String localM3u8Path,
    String outMp4,
    void Function(int bytes)? onProgress,
  ) async {
    StreamSubscription<android_native.RemuxProgress>? sub;
    if (onProgress != null) {
      sub = android_native.FfmpegRemux.progressStream.listen((e) {
        if (e.output == outMp4 && e.state == 'running') {
          onProgress(e.bytes);
        }
      });
    }
    try {
      final res = await android_native.FfmpegRemux.remux(
        input: localM3u8Path,
        output: outMp4,
      );
      return RemuxResult(ok: res.ret == 0, outMp4: res.output);
    } finally {
      await sub?.cancel();
    }
  }

  Future<RemuxResult> _remuxIos(
    String taskId,
    String localM3u8Path,
    String outMp4,
    void Function(int bytes)? onProgress,
  ) async {
    final completer = Completer<RemuxResult>();
    final sub = ios_native.FfmpegRemuxIos.eventStream.listen((e) {
      if (e.taskId != taskId) return;
      onProgress?.call((e.progress * 1e6).toInt());
      if (e.isDone && !completer.isCompleted) {
        completer.complete(
          RemuxResult(ok: e.isSuccess, outMp4: e.outPath ?? outMp4),
        );
      }
    });
    try {
      final ret = await ios_native.FfmpegRemuxIos.startRemux(
        taskId: taskId,
        inM3u8: localM3u8Path,
        outPath: outMp4,
      );
      if (ret < 0 && !completer.isCompleted) {
        completer.complete(
          const RemuxResult(ok: false, error: 'startRemux rejected'),
        );
      }
      return await completer.future;
    } finally {
      await sub.cancel();
    }
  }

  @override
  void cancel(String taskId) {
    if (Platform.isAndroid) {
      android_native.FfmpegRemux.cancel();
    } else if (Platform.isIOS) {
      ios_native.FfmpegRemuxIos.cancelRemux(taskId: taskId);
    }
  }

  @override
  Future<void> cleanup({
    required String dir,
    required String? outMp4,
    required bool success,
  }) async {
    if (!success) return;
    final directory = Directory(dir);
    if (!directory.existsSync()) return;
    final keep = outMp4 == null ? null : p.normalize(outMp4);
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      if (keep != null && p.normalize(entity.path) == keep) continue;
      try {
        await entity.delete();
      } catch (_) {
        // 尽力清理，忽略单个文件删除失败
      }
    }
  }
}
