import 'dart:async';
import 'package:flutter/services.dart';

class RemuxEvent {
  final String taskId;
  final String state; // running/completed/failed/canceled
  final double progress; // 0~1
  final int? ret; // completed ret=0, failed ret<0
  final String? outPath;
  final String? message;

  RemuxEvent({
    required this.taskId,
    required this.state,
    required this.progress,
    this.ret,
    this.outPath,
    this.message,
  });

  factory RemuxEvent.fromMap(Map<dynamic, dynamic> m) {
    int? asInt(dynamic v) => v == null || v is Null ? null : (v as num).toInt();
    String? asStr(dynamic v) => v == null || v is Null ? null : v as String;

    return RemuxEvent(
      taskId: (m['taskId'] ?? '') as String,
      state: (m['state'] ?? 'running') as String,
      progress: ((m['progress'] ?? 0.0) as num).toDouble(),
      ret: asInt(m['ret']),
      outPath: asStr(m['outPath']),
      message: asStr(m['message']),
    );
  }

  bool get isDone => state == 'completed' || state == 'failed' || state == 'canceled';
  bool get isSuccess => state == 'completed' && (ret ?? -1) == 0;
}

class FfmpegRemuxIos {
  static const MethodChannel _ch = MethodChannel('ffmpeg_remux');
  static const EventChannel _ev = EventChannel('ffmpeg_remux/progress');

  static Stream<RemuxEvent>? _stream;
  static Stream<RemuxEvent> get eventStream {
    _stream ??= _ev.receiveBroadcastStream().map((e) {
      return RemuxEvent.fromMap(e as Map<dynamic, dynamic>);
    });
    return _stream!;
  }

  /// 异步开始（iOS：后台线程跑，不堵 UI）
  /// 返回：0=accepted; <0=参数/平台错误（一般不会）
  static Future<int> startRemux({
    required String taskId,
    required String inM3u8,  // 传 local.m3u8 的绝对路径
    required String outPath, // 传 mp4 输出绝对路径
  }) async {
    final ret = await _ch.invokeMethod<int>('startRemux', {
      'taskId': taskId,
      'inM3u8': inM3u8,
      'outPath': outPath,
    });
    return ret ?? -1;
  }

  /// 软取消（真正中断需要你改 C 层加 interrupt_callback）
  static Future<void> cancelRemux({required String taskId}) async {
    await _ch.invokeMethod('cancelRemux', {'taskId': taskId});
  }
}