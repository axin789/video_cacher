import 'dart:async';
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


  final FutureOr<void> Function(M3u8Task)? onTaskUpdate;

  /// HLS 后处理注入（Android remux / iOS remux 或 proxy）
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

  void _notify(M3u8Task t) {
    final r = onTaskUpdate?.call(t);
    if (r is Future) {
      unawaited(r); //
    }
  }

  bool _isTerminal(M3u8Task t) =>
      t.status == TaskStatus.completed || t.status == TaskStatus.canceled;

  bool _inQueue(String taskId) => _queue.any((t) => t.taskId == taskId);

  void enqueue(M3u8Task task) {
    dev.log('[SCH] enqueue ${task.taskId} status=${task.status}');

    if (_isTerminal(task)) return;
    if (_active.containsKey(task.taskId) || _inQueue(task.taskId)) return;

    if (task.status == TaskStatus.running || task.status == TaskStatus.postProcessing) {
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

    Future.microtask(() {
      try {
        while (_active.length < maxActiveVideos && _queue.isNotEmpty) {
          final task = _queue.removeFirst();

          if (_isTerminal(task)) {
            _notify(task);
            continue;
          }
          if (_active.containsKey(task.taskId)) continue;

          final worker = _createWorker(task);
          _active[task.taskId] = worker;

          task.status = TaskStatus.running;
          _notify(task);

          worker.start().whenComplete(() {
            _active.remove(task.taskId);
            _notify(task);
            _pump();
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

  void resume(M3u8Task task) {
    if (task.status == TaskStatus.paused ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.queued) {
      task.status = TaskStatus.queued;
      enqueue(task);
    }
  }

  Future<void> cancel(String taskId, {bool deleteFiles = false}) async {
    final w = _active.remove(taskId);
    if (w != null) {
      await w.cancel(deleteFiles: deleteFiles);
      w.task.status = TaskStatus.canceled;
      _notify(w.task);
      _pump();
      return;
    }

    final list = _queue.toList();
    for (final t in list) {
      if (t.taskId == taskId) {
        _queue.remove(t);
        t.status = TaskStatus.canceled;

        if (deleteFiles) {
          try {
            final dir = Directory(t.dir);
            if (await dir.exists()) await dir.delete(recursive: true);
          } catch (_) {}
        }

        _notify(t);
        break;
      }
    }
  }

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
}