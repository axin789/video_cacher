import 'dart:convert';
import 'package:mmkv/mmkv.dart';

import '../model/m3u8_models.dart';
import 'task_store_base.dart';

class TaskStoreMmkv implements TaskStore {
  static const _boxName = 'download_tasks_v3';
  static const _keyTasks = 'tasks';

  final MMKV _box = MMKV(_boxName);

  @override
  Future<void> deleteTask(String id) async {
    final all = await loadTasks();
    all.remove(id);
    await saveTasks(all);
  }

  @override
  Future<Map<String, M3u8Task>> loadTasks() async {
    final s = _box.decodeString(_keyTasks);
    if (s == null || s.isEmpty) return {};
    final Map<String, dynamic> raw = jsonDecode(s);
    final out = <String, M3u8Task>{};
    raw.forEach((id, v) {
      try {
        out[id] = _fromJson(v as Map<String, dynamic>);
      } catch (_) {}
    });
    return out;
  }

  @override
  Future<void> saveTasks(Map<String, M3u8Task> tasks) async {
    final map = <String, dynamic>{};
    tasks.forEach((id, t) => map[id] = _toJson(t));
    _box.encodeString(_keyTasks, jsonEncode(map));
  }

  @override
  Future<void> upsertTask(M3u8Task task) async {
    final all = await loadTasks();
    all[task.taskId] = task;
    await saveTasks(all);
  }

  // ========================
  // serialize
  // ========================
  Map<String, dynamic> _toJson(M3u8Task t) {
    return {
      'taskId': t.taskId,
      'movieId': t.movieId,
      'lid': t.lid,
      'name': t.name,
      'coverImg': t.coverImg,
      'url': t.url,
      'dir': t.dir,

      'kind': t.kind.name,
      'status': t.status.name,

      // progress
      'completed': t.completed,
      'persistedTotal': (t.segments.isNotEmpty
          ? t.segments.length
          : (t.persistedTotal ?? 0)),
      'downloaded': t.downloaded,
      'contentLength': t.contentLength,

      // result
      'localPath': t.localPath,
      'mp4Path': t.mp4Path,
      'playUrl': t.playUrl,

      // misc
      'eTag': t.eTag,
      'tmpPath': t.tmpPath,
      'error': t.error,
    };
  }

  // ========================
  // deserialize + 修正状态
  // ========================
  M3u8Task _fromJson(Map<String, dynamic> v) {
    final statusName = (v['status'] as String?) ?? 'paused';
    var status = TaskStatus.values.firstWhere(
          (x) => x.name == statusName,
      orElse: () => TaskStatus.paused,
    );

    final kindName = (v['kind'] as String?) ?? 'hls';
    final kind = SourceKind.values.firstWhere(
          (e) => e.name == kindName,
      orElse: () => SourceKind.hls,
    );

    final mp4Path = v['mp4Path'] as String?;
    final playUrl = v['playUrl'] as String?;
    final localPath = v['localPath'] as String? ?? '';

    // ===== 冷启动状态修正 =====
    if (status == TaskStatus.running ||
        status == TaskStatus.postProcessing) {
      if (kind == SourceKind.hls) {
        if ((playUrl?.isNotEmpty ?? false) ||
            localPath.isNotEmpty) {
          status = TaskStatus.completed;
        } else {
          status = TaskStatus.paused;
        }
      } else {
        if (mp4Path?.isNotEmpty ?? false) {
          status = TaskStatus.completed;
        } else {
          status = TaskStatus.failed;
        }
      }
    }

    return M3u8Task(
      taskId: v['taskId'],
      movieId: v['movieId'],
      lid: v['lid'],
      name: v['name'],
      coverImg: v['coverImg'],
      url: v['url'],
      dir: v['dir'],

      kind: kind,
      status: status,

      segments: [],
      key: null,

      completed: (v['completed'] ?? 0) as int,
      persistedTotal: (v['persistedTotal'] ?? 0) as int,

      downloaded: (v['downloaded'] ?? 0) as int,
      contentLength: v['contentLength'],
      eTag: v['eTag'],
      tmpPath: v['tmpPath'],
      error: v['error'],

      localPath: localPath,
      mp4Path: mp4Path,
      playUrl: playUrl,
      remuxBytes: 0, // 重启后不恢复中间进度
    );
  }
}

// ========================
// MMKV init
// ========================
bool _inited = false;

Future<void> _ensureInited() async {
  if (_inited) return;
  await MMKV.initialize();
  _inited = true;
}

Future<TaskStore> openTaskStore() async {
  await _ensureInited();
  return TaskStoreMmkv();
}