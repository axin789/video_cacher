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
/// - 同一任务的落盘/删除经串行链按序执行；close 后的写入/删除被忽略。
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

  /// 每任务的串行操作链尾：同一 taskId 的磁盘操作按入队顺序执行。
  final Map<String, Future<void>> _chain = {};

  bool _dirEnsured = false;
  bool _closed = false;
  int _seq = 0;

  /// 把磁盘操作追加到该任务的串行链尾并返回新链尾。
  /// 操作异常在链内吞掉：链不断、也不逃逸到根 zone。
  Future<void> _enqueue(String taskId, Future<void> Function() op) {
    final tail = (_chain[taskId] ?? Future<void>.value()).then((_) async {
      try {
        await op();
      } catch (_) {
        // 落盘失败不影响链上后续操作。
      }
    });
    _chain[taskId] = tail;
    tail.whenComplete(() {
      if (identical(_chain[taskId], tail)) _chain.remove(taskId);
    });
    return tail;
  }

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
    // 链内已串行，唯一 tmp 名仅防多实例同名互踩。
    final tmp = File('${file.path}.${_seq++}.tmp');
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
    if (_closed) return;
    final previous = _tasks[task.taskId];
    _tasks[task.taskId] = task;

    final statusChanged = previous == null || previous.status != task.status;
    if (statusChanged) {
      _timers.remove(task.taskId)?.cancel();
      await _enqueue(task.taskId, () => _writeAtomic(task));
      return;
    }

    // 纯进度更新：按 taskId 去抖，写入最新快照。
    _timers[task.taskId]?.cancel();
    _timers[task.taskId] = Timer(debounceInterval, () {
      _timers.remove(task.taskId);
      try {
        _enqueue(task.taskId, () async {
          final latest = _tasks[task.taskId];
          if (latest != null) await _writeAtomic(latest);
        });
      } catch (_) {
        // 兜底：任何异常都不逃逸到根 zone。
      }
    });
  }

  @override
  Future<void> delete(String taskId) async {
    _guardId(taskId);
    if (_closed) return;
    _timers.remove(taskId)?.cancel();
    _tasks.remove(taskId);
    await _enqueue(taskId, () async {
      try {
        await _fileFor(taskId).delete();
      } on FileSystemException {
        // 不存在则忽略。
      }
      // 顺带清理该任务遗留的 tmp 文件（<id>.json.<seq>.tmp）。
      try {
        await for (final e in _tasksDir.list()) {
          if (e is File && e.uri.pathSegments.last.startsWith('$taskId.json.')) {
            try {
              await e.delete();
            } on FileSystemException {
              // 忽略。
            }
          }
        }
      } on FileSystemException {
        // 目录不存在则忽略。
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    // 先置位：close 开始后的新写入/删除一律忽略。
    _closed = true;
    final dirty = _timers.keys.toList();
    for (final id in dirty) {
      _timers.remove(id)?.cancel();
    }
    for (final id in dirty) {
      _enqueue(id, () async {
        final task = _tasks[id];
        if (task != null) await _writeAtomic(task);
      });
    }
    await Future.wait(_chain.values.toList());
  }
}
