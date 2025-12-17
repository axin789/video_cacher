import 'dart:collection';
import 'dart:developer' as dev;
import 'dart:io';
import 'package:dio/dio.dart';

import 'model/m3u8_models.dart';
import 'processor/post_processor.dart';
import 'worker/base_worker.dart';
import 'worker/hls_worker.dart';
import 'worker/mp4_worker.dart';

class DownloadScheduler {
  final Dio dio;
  final int maxActiveVideos;
  final void Function(M3u8Task)? onTaskUpdate;

  final PostProcessor postProcessor;

  final Queue<M3u8Task> _queue = Queue();
  final Map<String, BaseWorker<M3u8Task>> _active = {};

  bool _pumping = false;

  DownloadScheduler({
    required this.dio,
    required this.postProcessor,
    this.maxActiveVideos = 3,
    this.onTaskUpdate,
  });

  bool isActive(String taskId) => _active.containsKey(taskId);
  int get activeCount => _active.length;

  void _notify(M3u8Task t) => onTaskUpdate?.call(t);

  bool _isTerminal(M3u8Task t) =>
      t.status == TaskStatus.completed || t.status == TaskStatus.canceled;

  bool _inQueue(String taskId) => _queue.any((t) => t.taskId == taskId);

  void enqueue(M3u8Task task) {
    dev.log('[SCH] enqueue ${task.taskId} status=${task.status} active=${_active.containsKey(task.taskId)} q=${_queue.any((t)=>t.taskId==task.taskId)}');

    // 已完成/已取消不进队列
    if (_isTerminal(task)) return;

    // 正在 active / 已在队列里不重复入队
    if (_active.containsKey(task.taskId) || _inQueue(task.taskId)) return;

    // 只有这些状态才允许 enqueue
    if (task.status == TaskStatus.running || task.status == TaskStatus.postProcessing) {
      // 避免把运行中任务又塞回队列
      return;
    }

    task.status = TaskStatus.queued;
    _queue.add(task);
    _notify(task);

    _pump();
  }

  void _pump() {
    if (_pumping) return;
    _pumping = true;

    // 用微任务避免递归 re-entrancy（稳定）
    Future.microtask(() async {
      try {
        while (_active.length < maxActiveVideos && _queue.isNotEmpty) {
          final task = _queue.removeFirst();

          // 兜底：被外部改成 completed/canceled 直接跳过
          if (_isTerminal(task)) {
            _notify(task);
            continue;
          }

          // 兜底：如果已经 active（理论不会发生），跳过
          if (_active.containsKey(task.taskId)) continue;

          final worker = _createWorker(task);
          _active[task.taskId] = worker;

          task.status = TaskStatus.running;
          _notify(task);

          // 不 await，让它并发跑，但结束时一定回收并继续 pump
          worker.start().whenComplete(() {
            _active.remove(task.taskId);
            _notify(task);
            _pump(); // 继续拉队列
          });
        }
      } finally {
        _pumping = false;
      }
    });
  }

  BaseWorker<M3u8Task> _createWorker(M3u8Task task) {
    switch (task.kind) {
      case SourceKind.hls:
        return HlsWorker(
          dio: dio,
          task: task,
          segConcurrency: 2,
          postProcessor: postProcessor,
          onProgress: _notify,
          onDone: _notify,
        );
      case SourceKind.mp4:
        return Mp4Worker(
          dio: dio,
          task: task,
          onProgress: _notify,
          onDone: _notify,
        );
    }
  }

  /// 暂停：如果正在执行，先让 worker 停；并从 active 移除，重新 pump。
  void pause(String taskId) {
    final w = _active.remove(taskId);
    if (w != null) {
      w.pause();
      final t = w.task;
      t.status = TaskStatus.paused;
      _notify(t);
      _pump();
      return;
    }

    // 如果在队列里：移除并标记 paused
    final list = _queue.toList();
    for (final t in list) {
      if (t.taskId == taskId) {
        _queue.remove(t);
        t.status = TaskStatus.paused;
        _notify(t);
        break;
      }
    }
  }

  void forceRetry(String taskId) {
    // 1) 如果还在 active：先 pause/cancel
    final w = _active.remove(taskId);
    if (w != null) {
      try { w.pause(); } catch (_) {}
    }

    // 2) 从 queue 移除
    _queue.removeWhere((t) => t.taskId == taskId);
  }

  void resume(M3u8Task task) {
    if (task.status == TaskStatus.paused || task.status == TaskStatus.failed || task.status == TaskStatus.queued) {
      task.status = TaskStatus.queued;
      enqueue(task);
    }
  }

  Future<void> cancel(String taskId, {bool deleteFiles = false}) async {
    // active：先取消 worker
    final w = _active.remove(taskId);
    if (w != null) {
      await w.cancel(deleteFiles: deleteFiles);
      w.task.status = TaskStatus.canceled;
      _notify(w.task);
      _pump();
      return;
    }

    // queue：移除并 cancel
    final list = _queue.toList();
    for (final t in list) {
      if (t.taskId == taskId) {
        _queue.remove(t);
        t.status = TaskStatus.canceled;

        if (deleteFiles) {
          try {
            final dir = Directory(t.dir);
            if (await dir.exists()) {
              await dir.delete(recursive: true);
            }
          } catch (_) {}
        }

        _notify(t);
        break;
      }
    }
  }

  /// 把队列中的 task 拉到最前
  void prioritize(String taskId) {
    final list = _queue.toList();
    final idx = list.indexWhere((t) => t.taskId == taskId);
    if (idx < 0) return;

    final t = list.removeAt(idx);
    _queue
      ..clear()
      ..addFirst(t)
      ..addAll(list);

    _notify(t);
    _pump();
  }

  Future<void> cancelAll({bool deleteFiles = false}) async {
    final keys = _active.keys.toList();
    for (final id in keys) {
      await cancel(id, deleteFiles: deleteFiles);
    }
    // cancel queued
    final queued = _queue.toList();
    _queue.clear();
    for (final t in queued) {
      t.status = TaskStatus.canceled;
      if (deleteFiles) {
        try {
          final dir = Directory(t.dir);
          if (await dir.exists()) await dir.delete(recursive: true);
        } catch (_) {}
      }
      _notify(t);
    }
  }
}