import 'dart:async';
import 'package:flutter/services.dart';

// 对外公开 API（纯 Dart 重写）。原生桥 FfmpegRemux 类保留在本文件下方，
// ffmpeg 兜底 remux 仍依赖它，Phase 3 再做结构调整。
export 'src/api/download_manager.dart';
export 'src/api/models/download_task.dart';
export 'src/api/models/task_status.dart'; // TaskStatus, SourceKind
export 'src/api/models/task_event.dart';
export 'src/api/models/download_config.dart';
export 'src/album/album_saver.dart'; // AlbumSaveResult

class RemuxResult {
  final int ret;
  final String output;
  RemuxResult(this.ret, this.output);
}

class RemuxProgress {
  final String state; // started/running/done/error/cancelled，表示当前任务状态
  final String? output;
  final int? ret;
  final int bytes; // 输出文件大小，单位字节
  RemuxProgress({
    required this.state,
    required this.bytes,
    this.output,
    this.ret,
  });

  factory RemuxProgress.fromMap(Map<dynamic, dynamic> m) {
    return RemuxProgress(
      state: (m['state'] as String?) ?? 'running',
      output: m['output'] as String?,
      ret: m['ret'] as int?,
      bytes: (m['bytes'] as int?) ?? 0,
    );
  }
}

class FfmpegRemux {
  static const MethodChannel _m = MethodChannel('ffmpeg_remux/methods');
  static const EventChannel _e = EventChannel('ffmpeg_remux/progress');

  static Stream<RemuxProgress>? _progressStream;

  static Stream<RemuxProgress> get progressStream {
    _progressStream ??= _e
        .receiveBroadcastStream()
        .map((event) => RemuxProgress.fromMap(event as Map));
    return _progressStream!;
  }

  static Future<RemuxResult> remux({
    required String input,
    required String output,
  }) async {
    final map = await _m.invokeMapMethod<String, dynamic>('remux', {
      'input': input,
      'output': output,
    });

    final ret = (map?['ret'] as int?) ?? -1;
    final out = (map?['output'] as String?) ?? output;
    return RemuxResult(ret, out);
  }

  static Future<bool> cancel() async {
    final ok = await _m.invokeMethod<bool>('cancel');
    return ok ?? false;
  }
}
