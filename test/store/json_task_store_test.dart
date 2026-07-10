import 'dart:convert';
import 'dart:io';

import 'package:video_cacher/src/api/models/download_task.dart';
import 'package:video_cacher/src/api/models/task_status.dart';
import 'package:video_cacher/src/store/json_task_store.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task(
  String id, {
  TaskStatus status = TaskStatus.queued,
  int downloadedBytes = 0,
}) {
  return DownloadTask(
    taskId: id,
    movieId: 'm_$id',
    name: 'name_$id',
    coverImg: 'cover_$id',
    url: 'https://example.com/$id.m3u8',
    dir: '/tmp/$id',
    kind: SourceKind.hls,
    createdAtMs: 1000,
    status: status,
    totalBytes: 100,
    downloadedBytes: downloadedBytes,
  );
}

void main() {
  late Directory baseDir;

  setUp(() {
    baseDir = Directory.systemTemp.createTempSync('json_task_store_test');
  });

  tearDown(() {
    if (baseDir.existsSync()) baseDir.deleteSync(recursive: true);
  });

  File taskFile(String id) =>
      File('${baseDir.path}/tasks/$id.json');

  test('round-trip: upsert then reload returns equal task', () async {
    final store = JsonTaskStore(baseDir);
    final task = _task('a', status: TaskStatus.running);
    await store.upsert(task);
    await store.close();

    final store2 = JsonTaskStore(baseDir);
    final loaded = await store2.loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single, equals(task));
  });

  test('status change flushes file immediately (no close needed)', () async {
    final store = JsonTaskStore(baseDir);
    await store.upsert(_task('a', status: TaskStatus.running));
    expect(taskFile('a').existsSync(), isTrue);
  });

  test('debounce coalesces progress; final on-disk equals last upsert',
      () async {
    final store = JsonTaskStore(
      baseDir,
      debounceInterval: const Duration(milliseconds: 50),
    );
    // First upsert (new task) writes immediately at status queued.
    await store.upsert(_task('a', downloadedBytes: 1));
    // Progress-only updates (same status) -> debounced.
    await store.upsert(_task('a', downloadedBytes: 2));
    await store.upsert(_task('a', downloadedBytes: 3));
    await store.upsert(_task('a', downloadedBytes: 42));

    await store.close();

    final onDisk = DownloadTask.fromJson(
      jsonDecode(taskFile('a').readAsStringSync()) as Map<String, dynamic>,
    );
    expect(onDisk.downloadedBytes, 42);
  });

  test('corrupt file is skipped, not fatal', () async {
    final store = JsonTaskStore(baseDir);
    await store.upsert(_task('good', status: TaskStatus.running));

    File('${baseDir.path}/tasks/garbage.json')
        .writeAsStringSync('{not valid json');

    final loaded = await JsonTaskStore(baseDir).loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.taskId, 'good');
  });

  test('stray .tmp file is ignored by loadAll', () async {
    final store = JsonTaskStore(baseDir);
    await store.upsert(_task('a', status: TaskStatus.running));

    File('${baseDir.path}/tasks/a.json.tmp')
        .writeAsStringSync('leftover garbage');

    final loaded = await JsonTaskStore(baseDir).loadAll();
    expect(loaded, hasLength(1));
    expect(loaded.single.taskId, 'a');
  });

  test('delete removes file and it no longer appears in loadAll', () async {
    final store = JsonTaskStore(baseDir);
    await store.upsert(_task('a', status: TaskStatus.running));
    expect(taskFile('a').existsSync(), isTrue);

    await store.delete('a');
    expect(taskFile('a').existsSync(), isFalse);

    final loaded = await JsonTaskStore(baseDir).loadAll();
    expect(loaded, isEmpty);
  });
}
