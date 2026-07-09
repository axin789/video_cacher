import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/models/download_task.dart';
import 'task_store.dart';

/// 基于 JSON 文件的任务存储（每任务一个文件 + 原子写 + 去抖）。
///
/// - 每条任务持久化到 `<baseDir>/tasks/<taskId>.json`。
/// - 写入先落 `.tmp` 再 `rename`，保证同盘原子替换。
/// - 状态变更立即刷盘；纯进度更新按 [debounceInterval] 去抖合并。
///
/// 纯 Dart 实现，不依赖 path_provider —— 基目录由调用方注入，便于单测。
class JsonTaskStore implements TaskStore {
  JsonTaskStore(
    Object baseDir, {
    this.debounceInterval = const Duration(seconds: 1),
  }) : _tasksDir = Directory(
          '${baseDir is Directory ? baseDir.path : baseDir as String}'
          '${Platform.pathSeparator}tasks',
        );

  final Directory _tasksDir;
  final Duration debounceInterval;

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, Timer> _timers = {};

  bool _dirEnsured = false;

  Future<void> _ensureDir() async {
    if (_dirEnsured) return;
    await _tasksDir.create(recursive: true);
    _dirEnsured = true;
  }

  File _fileFor(String taskId) =>
      File('${_tasksDir.path}${Platform.pathSeparator}$taskId.json');

  /// 拒绝含路径分隔符的非法 taskId，避免越出 tasks 目录。
  void _guardId(String taskId) {
    if (taskId.isEmpty ||
        taskId.contains('/') ||
        taskId.contains(r'\') ||
        taskId == '.' ||
        taskId == '..') {
      throw ArgumentError.value(taskId, 'taskId', '非法的 taskId');
    }
  }

  Future<void> _writeAtomic(DownloadTask task) async {
    await _ensureDir();
    final file = _fileFor(task.taskId);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(task.toJson()), flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<List<DownloadTask>> loadAll() async {
    await _ensureDir();
    _tasks.clear();
    await for (final entity in _tasksDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        final map = jsonDecode(await entity.readAsString()) as Map<String, dynamic>;
        final task = DownloadTask.fromJson(map);
        _tasks[task.taskId] = task;
      } catch (_) {
        // 坏文件跳过，不影响其余任务加载。
      }
    }
    return _tasks.values.toList();
  }

  @override
  Future<void> upsert(DownloadTask task) async {
    _guardId(task.taskId);
    final previous = _tasks[task.taskId];
    _tasks[task.taskId] = task;

    final statusChanged = previous == null || previous.status != task.status;
    if (statusChanged) {
      _timers.remove(task.taskId)?.cancel();
      await _writeAtomic(task);
      return;
    }

    // 纯进度更新：按 taskId 去抖，写入最新快照。
    _timers[task.taskId]?.cancel();
    _timers[task.taskId] = Timer(debounceInterval, () async {
      _timers.remove(task.taskId);
      final latest = _tasks[task.taskId];
      if (latest != null) await _writeAtomic(latest);
    });
  }

  @override
  Future<void> delete(String taskId) async {
    _guardId(taskId);
    _timers.remove(taskId)?.cancel();
    _tasks.remove(taskId);
    final file = _fileFor(taskId);
    final tmp = File('${file.path}.tmp');
    if (await file.exists()) await file.delete();
    if (await tmp.exists()) await tmp.delete();
  }

  @override
  Future<void> close() async {
    final pending = _timers.keys.toList();
    for (final id in pending) {
      _timers.remove(id)?.cancel();
    }
    for (final id in pending) {
      final task = _tasks[id];
      if (task != null) await _writeAtomic(task);
    }
  }
}
