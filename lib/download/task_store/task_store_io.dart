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

  Map<String, dynamic> _toJson(M3u8Task t) {
    return {
      'taskId': t.taskId,
      'movieId': t.movieId,
      'lid': t.lid,
      'name': t.name,
      'coverImg': t.coverImg,
      'url': t.url,
      'dir': t.dir,
      'status': t.status.name,
      'completed': t.completed,
      'persistedTotal': (t.segments.isNotEmpty ? t.segments.length : (t.persistedTotal ?? 0)),
      'error': t.error,
      'kind': t.kind.name,

      // mp4 download
      'contentLength': t.contentLength,
      'downloaded': t.downloaded,
      'eTag': t.eTag,
      'tmpPath': t.tmpPath,

      // outputs
      'localPath': t.localPath,
      'mp4Path': t.mp4Path,
      'hlsLocalM3u8Path': t.hlsLocalM3u8Path,

      // album
      'albumSaved': t.albumSaved,
      'saveToAlbum': t.saveToAlbum,
      'albumError': t.albumError,

      // extras
      'remuxBytes': t.remuxBytes,
      'postAttempts': t.postAttempts,
    };
  }

  M3u8Task _fromJson(Map<String, dynamic> v) {
    final statusName = (v['status'] as String?) ?? 'paused';
    final st = TaskStatus.values.firstWhere(
          (x) => x.name == statusName,
      orElse: () => TaskStatus.paused,
    );

    final kindName = (v['kind'] as String?) ?? 'hls';
    final kd = SourceKind.values.firstWhere(
          (e) => e.name == kindName,
      orElse: () => SourceKind.hls,
    );

    return M3u8Task(
      taskId: v['taskId'],
      movieId: v['movieId'],
      lid: v['lid'],
      name: v['name'],
      coverImg: v['coverImg'],
      url: v['url'],
      dir: v['dir'],

      // hls
      segments: [],
      key: null,
      hlsLocalM3u8Path: v['hlsLocalM3u8Path'] as String?,

      // common
      status: st,
      kind: kd,
      completed: (v['completed'] ?? 0) as int,
      persistedTotal: (v['persistedTotal'] ?? 0) as int,
      error: v['error'] as String?,

      // mp4 download
      eTag: v['eTag'] as String?,
      tmpPath: v['tmpPath'] as String?,
      contentLength: v['contentLength'] as int?,
      downloaded: (v['downloaded'] ?? 0) as int,

      // outputs
      localPath: v['localPath'] as String?,
      mp4Path: v['mp4Path'] as String?,

      // album
      albumSaved: (v['albumSaved'] ?? false) as bool,
      saveToAlbum: (v['saveToAlbum'] ?? true) as bool,
      albumError: v['albumError'] as String?,

      // extras
      remuxBytes: (v['remuxBytes'] ?? 0) as int,
      postAttempts: (v['postAttempts'] ?? 0) as int,
    );
  }
}

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