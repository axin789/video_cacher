import 'dart:async';
import 'package:flutter/services.dart';

class RemuxEvent {
  final String taskId;
  final String state; // running/completed/failed/canceled，表示转换状态
  final double progress; // 0~1，表示当前转换进度
  final int? ret; // completed 时 ret=0，failed 时 ret<0
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
    int? asInt(dynamic v) => v == null || v == null ? null : (v as num).toInt();
    String? asStr(dynamic v) => v == null || v == null ? null : v as String;

    return RemuxEvent(
      taskId: (m['taskId'] ?? '') as String,
      state: (m['state'] ?? 'running') as String,
      progress: ((m['progress'] ?? 0.0) as num).toDouble(),
      ret: asInt(m['ret']),
      outPath: asStr(m['outPath']),
      message: asStr(m['message']),
    );
  }

  bool get isDone =>
      state == 'completed' || state == 'failed' || state == 'canceled';
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

  /// 异步开始转换（iOS 在后台线程执行，不阻塞界面）
  /// 返回：0 表示已接受任务，<0 表示参数或平台错误
  static Future<int> startRemux({
    required String taskId,
    required String inM3u8, // 传入 local.m3u8 的绝对路径
    required String outPath, // 传入 mp4 输出文件绝对路径
  }) async {
    final ret = await _ch.invokeMethod<int>('startRemux', {
      'taskId': taskId,
      'inM3u8': inM3u8,
      'outPath': outPath,
    });
    return ret ?? -1;
  }

  /// 软取消（如果需要真正中断，需要在 C 层补 interrupt_callback）
  static Future<void> cancelRemux({required String taskId}) async {
    await _ch.invokeMethod('cancelRemux', {'taskId': taskId});
  }
}
