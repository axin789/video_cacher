import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../model/m3u8_models.dart';
import 'task_store_base.dart';

class TaskStoreSqlite implements TaskStore {
  final Database _db;

  TaskStoreSqlite(this._db) {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS tasks (
        id TEXT PRIMARY KEY,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  @override
  Future<void> deleteTask(String id) async {
    final stmt = _db.prepare('DELETE FROM tasks WHERE id = ?');
    stmt.execute([id]);
    stmt.dispose();
  }

  @override
  Future<Map<String, M3u8Task>> loadTasks() async {
    final out = <String, M3u8Task>{};
    final rs = _db.select('SELECT id, payload FROM tasks');
    for (final row in rs) {
      try {
        final id = row['id'] as String;
        final map =
            jsonDecode(row['payload'] as String) as Map<String, dynamic>;
        out[id] = _fromJson(map);
      } catch (_) {}
    }
    return out;
  }

  @override
  Future<void> saveTasks(Map<String, M3u8Task> tasks) async {
    _db.execute('DELETE FROM tasks');
    final stmt = _db.prepare(
        'INSERT OR REPLACE INTO tasks (id, payload, updated_at) VALUES (?, ?, ?)');
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final e in tasks.entries) {
      stmt.execute([e.key, jsonEncode(_toJson(e.value)), now]);
    }
    stmt.dispose();
  }

  @override
  Future<void> upsertTask(M3u8Task task) async {
    final stmt = _db.prepare(
        'INSERT OR REPLACE INTO tasks (id, payload, updated_at) VALUES (?, ?, ?)');
    stmt.execute([
      task.taskId,
      jsonEncode(_toJson(task)),
      DateTime.now().millisecondsSinceEpoch
    ]);
    stmt.dispose();
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
      'persistedTotal':
          (t.segments.isNotEmpty ? t.segments.length : (t.persistedTotal ?? 0)),
      'error': t.error,
      'kind': t.kind.name,
      'contentLength': t.contentLength,
      'downloaded': t.downloaded,
      'eTag': t.eTag,
      'tmpPath': t.tmpPath,
      'localPath': t.localPath,
      'mp4Path': t.mp4Path,
      'hlsLocalM3u8Path': t.hlsLocalM3u8Path,
      'albumSaved': t.albumSaved,
      'saveToAlbum': t.saveToAlbum,
      'albumError': t.albumError,
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
      segments: [],
      key: null,
      hlsLocalM3u8Path: v['hlsLocalM3u8Path'] as String?,
      status: st,
      kind: kd,
      completed: (v['completed'] ?? 0) as int,
      persistedTotal: (v['persistedTotal'] ?? 0) as int,
      error: v['error'] as String?,
      eTag: v['eTag'] as String?,
      tmpPath: v['tmpPath'] as String?,
      contentLength: v['contentLength'] as int?,
      downloaded: (v['downloaded'] ?? 0) as int,
      localPath: v['localPath'] as String?,
      mp4Path: v['mp4Path'] as String?,
      albumSaved: (v['albumSaved'] ?? false) as bool,
      saveToAlbum: (v['saveToAlbum'] ?? true) as bool,
      albumError: v['albumError'] as String?,
      remuxBytes: (v['remuxBytes'] ?? 0) as int,
      postAttempts: (v['postAttempts'] ?? 0) as int,
    );
  }
}

Future<TaskStore> openTaskStore() async {
  final dir = await getApplicationSupportDirectory();
  await Directory(dir.path).create(recursive: true);
  final dbPath = p.join(dir.path, 'ffmpeg_remux_tasks.db');
  final db = sqlite3.open(dbPath);
  return TaskStoreSqlite(db);
}
