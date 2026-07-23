import 'dart:async';
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

  test('back-to-back status writes: on-disk state equals the second', () async {
    final store = JsonTaskStore(baseDir);
    for (var i = 0; i < 50; i++) {
      // 两次状态变更 upsert 背靠背发出（不逐个 await），模拟引擎 fire-and-forget。
      final w1 = store.upsert(_task('a', status: TaskStatus.queued));
      final w2 = store.upsert(_task('a', status: TaskStatus.running));
      await w1;
      await w2;
      final onDisk = DownloadTask.fromJson(
        jsonDecode(taskFile('a').readAsStringSync()) as Map<String, dynamic>,
      );
      expect(onDisk.status, TaskStatus.running, reason: 'iteration $i');
    }
  });

  test('no ghost file after delete racing an in-flight upsert', () async {
    final store = JsonTaskStore(baseDir);
    for (var i = 0; i < 50; i++) {
      final id = 'g$i';
      // 状态变更 upsert 不 await（引擎 .ignore() 场景），紧接着 delete。
      final w = store.upsert(_task(id, status: TaskStatus.running));
      await store.delete(id);
      await w;
      expect(taskFile(id).existsSync(), isFalse, reason: 'iteration $i');
      final leftovers = Directory('${baseDir.path}/tasks')
          .listSync()
          .where((e) => e.uri.pathSegments.last.startsWith('$id.json'))
          .toList();
      expect(leftovers, isEmpty, reason: 'iteration $i');
    }
  });

  test('upsert/delete after close are ignored', () async {
    final store = JsonTaskStore(
      baseDir,
      debounceInterval: const Duration(milliseconds: 20),
    );
    await store.close();
    await store.upsert(_task('x', status: TaskStatus.running));
    await store.delete('x');
    // 等超过去抖间隔，确认也没有定时器落盘。
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final tasksDir = Directory('${baseDir.path}/tasks');
    expect(
      !tasksDir.existsSync() || tasksDir.listSync().isEmpty,
      isTrue,
    );
  });

  test('debounced write racing delete: no zone error, no ghost, no throw',
      () async {
    var zoneErrors = 0;
    var ghosts = 0;
    var deleteThrew = 0;
    final done = Completer<void>();
    runZonedGuarded(() async {
      for (var i = 0; i < 50; i++) {
        final id = 'z$i';
        final store = JsonTaskStore(baseDir, debounceInterval: Duration.zero);
        await store.upsert(_task(id, status: TaskStatus.running));
        // 纯进度更新 -> 去抖 Timer(0)。
        await store.upsert(
          _task(id, status: TaskStatus.running, downloadedBytes: 10),
        );
        await Future<void>.delayed(Duration.zero); // 让 timer 回调先跑起来
        try {
          await store.delete(id);
        } catch (_) {
          deleteThrew++;
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
        if (taskFile(id).existsSync()) ghosts++;
      }
      done.complete();
    }, (e, s) => zoneErrors++);
    await done.future;
    expect(zoneErrors, 0);
    expect(ghosts, 0);
    expect(deleteThrew, 0);
  });
}
