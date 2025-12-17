

import 'dart:async';
import 'package:flutter/services.dart';

class RemuxResult {
  final int ret;
  final String output;
  RemuxResult(this.ret, this.output);
}

class RemuxProgress {
  final String state; // started/running/done/error/cancelled
  final String? output;
  final int? ret;
  final int bytes; // output file size bytes
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

