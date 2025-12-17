import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'download_scheduler.dart';
import 'local_video_server.dart';
import 'model/download_event.dart';
import 'model/m3u8_models.dart';
import 'processor/android_remux_post_processor.dart';
import 'processor/ios_post_processor.dart';
import 'processor/post_processor.dart';
import 'task_store/task_store.dart';
import 'task_store/task_store_base.dart';
import 'utils/source_detector.dart';

class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  bool _inited = false;

  late final PostProcessor _postProcessor;
  late Dio dio;
  late DownloadScheduler scheduler;
  late final TaskStore store;
  Directory? baseDir;

  final Map<String, M3u8Task> _tasks = {};
  final _controller = StreamController<M3u8Task>.broadcast();

  final _eventController = StreamController<DownloadEvent>.broadcast();
  Stream<DownloadEvent> get eventStream => _eventController.stream;

// 用来做“变化检测”
  final Map<String, TaskStatus> _lastStatus = {};
  final Map<String, int> _lastCompleted = {};
  final Map<String, int> _lastDownloaded = {};
  final Map<String, int> _lastRemuxBytes = {};

  Stream<M3u8Task> get taskStream => _controller.stream;
  Map<String, M3u8Task> get tasks => _tasks;

  Future<void> ensureInitialized() async {
    if (_inited) return;

    // iOS：启动本地代理
    if (Platform.isIOS) {
      await LocalVideoServer().ensureRunning();
      _postProcessor = IosPostProcessor();
    } else {
      _postProcessor = AndroidRemuxPostProcessor();
    }

    // 1) 打开 store
    store = await openTaskStore();

    // 2) base dir（建议 Support，更像缓存/离线数据目录）
    baseDir = await getApplicationSupportDirectory();


    // 3) Dio 只创建一次
    dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'm3u8/2.0'},
        followRedirects: true,
      ),
    );

    // 4) 恢复历史任务（先恢复内存）
    final restored = await store.loadTasks();
    _tasks.addAll(restored);

    // 5) 建 Scheduler
    scheduler = DownloadScheduler(
      dio: dio,
      postProcessor: _postProcessor,
      maxActiveVideos: 3,
      onTaskUpdate: (t) async {
        _tasks[t.taskId] = t;
        await store.upsertTask(t);
        _controller.add(t);
        _emitTaskEvent(t);
      },
    );

    // 6) 自动恢复：只恢复 queued（或 paused 也可按你策略）
    for (final t in _tasks.values) {
      if (t.status == TaskStatus.queued) {
        scheduler.enqueue(t);
      }
    }

    _inited = true;
  }

  /// 业务新增任务/继续任务
  Future<M3u8Task> addOrResumeFormMeta({
    required String taskId,
    required String movieId,
    required String lid,
    required String name,
    required String coverImg,
    required String url,
  }) async {
    await ensureInitialized();
    final dir = p.join(baseDir!.path, 'm3u8_task', taskId);

    final existing = _tasks[taskId];
    if (existing != null) {
      if (!existing.isFinished) scheduler.resume(existing);
      return existing;
    }

    final kind = await SourceDetector(dio).detect(url);

    final task = M3u8Task.fromMeta(
      taskId: taskId,
      movieId: movieId,
      kind: kind,
      lid: lid,
      name: name,
      coverImg: coverImg,
      url: url,
      dir: dir,
    );
    _tasks[taskId] = task;
    await store.upsertTask(task);
    _controller.add(task);
    _emitTaskEvent(task, isNew: true);
    scheduler.enqueue(task);
    return task;
  }

  Future<void> retryPostProcess(String taskId) async {
    await ensureInitialized();
    final t = _tasks[taskId];
    if (t == null) return;

    scheduler.forceRetry(taskId);

    t.status = TaskStatus.queued;
    t.error = null;

    scheduler.enqueue(t);

    _controller.add(t);
    await store.upsertTask(t);
  }

  // 常用操作封装
  void pause(String taskId) => scheduler.pause(taskId);

  void resumeById(String taskId) {
    final t = _tasks[taskId];
    if (t != null) scheduler.resume(t);
  }

  Future<void> cancel(String taskId, {bool deleteFiles = false}) async {
    await scheduler.cancel(taskId, deleteFiles: deleteFiles);
  }

  // 删除任务：不管状态，先取消，再删目录与记录
  Future<void> deleteTaskById(String taskId) async {
    await ensureInitialized();
    final t = _tasks[taskId];
    if (t == null) return;

    try {
      await cancel(taskId, deleteFiles: false);
    } catch (_) {}

    try {
      final dir = Directory(t.dir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}

    _tasks.remove(taskId);
    await store.deleteTask(taskId);
    // 也通知 UI
    _controller.add(t);
    _lastStatus.remove(taskId);
    _lastCompleted.remove(taskId);
    _lastDownloaded.remove(taskId);
    _lastRemuxBytes.remove(taskId);

    _eventController.add(DownloadEvent(type: DownloadEventType.removed, task: t));
  }



  /// 未完成列表
  List<M3u8Task> getUnfinished() {
    return _tasks.values
        .where((t) => !t.isFinished && t.status != TaskStatus.canceled)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// 根据一组 id 给出状态分类
  Map<String, List<String>> classifyByIds(Iterable<String> ids) {
    final downloaded = <String>[];
    final active = <String>[];
    final paused = <String>[];
    final missing = <String>[];

    for (final id in ids) {
      final t = _tasks[id];

      if (t == null) {
        missing.add(id);
        continue;
      }

      if (t.status == TaskStatus.completed) {
        downloaded.add(id);
      } else if (t.status == TaskStatus.running || t.status == TaskStatus.queued || t.status == TaskStatus.postProcessing) {
        active.add(id);
      } else {
        paused.add(id);
      }
    }

    return {
      'downloaded': downloaded,
      'active': active,
      'paused': paused,
      'missing': missing,
    };
  }

  void _emitTaskEvent(M3u8Task t, {bool isNew = false}) {
    final prevStatus = _lastStatus[t.taskId];
    final prevCompleted = _lastCompleted[t.taskId] ?? 0;
    final prevDownloaded = _lastDownloaded[t.taskId] ?? 0;
    final prevRemux = _lastRemuxBytes[t.taskId] ?? 0;

    // 更新快照
    _lastStatus[t.taskId] = t.status;
    _lastCompleted[t.taskId] = t.completed;
    _lastDownloaded[t.taskId] = t.downloaded;
    _lastRemuxBytes[t.taskId] = t.remuxBytes;

    // 1) 新增任务
    if (isNew) {
      _eventController.add(DownloadEvent(type: DownloadEventType.taskAdded, task: t));
    }

    // 2) status 变化
    if (prevStatus != null && prevStatus != t.status) {
      _eventController.add(DownloadEvent(
        type: DownloadEventType.statusChanged,
        task: t,
        fromStatus: prevStatus,
        toStatus: t.status,
      ));
    }

    // 3) progress 变化（HLS 用 completed；MP4 用 downloaded；remux 用 remuxBytes）
    final progressChanged =
        (t.completed != prevCompleted) ||
            (t.downloaded != prevDownloaded) ||
            (t.remuxBytes != prevRemux);

    if (progressChanged) {
      _eventController.add(DownloadEvent(type: DownloadEventType.progress, task: t));
    }

    // 4) 结束事件
    if (t.status == TaskStatus.completed ||
        t.status == TaskStatus.failed ||
        t.status == TaskStatus.canceled) {
      _eventController.add(DownloadEvent(type: DownloadEventType.finished, task: t));
    }

    // 5) 兜底：任何更新都发
    _eventController.add(DownloadEvent(type: DownloadEventType.taskUpdated, task: t));
  }

  /// 获取已下载的 ID 列表
  List<String> getDownloadedIds() {
    return _tasks.values
        .where((t) => t.status == TaskStatus.completed)
        .map((t) => t.taskId)
        .toList();
  }

  /// 更严格的“是否已下载”检查
  Future<bool> isDownloadedString(String id) async {
    final t = _tasks[id];
    if (t == null) return false;
    if (t.status == TaskStatus.completed) return true;

    // worker 写的是 local.m3u8
    final localM3u8 = File(p.join(t.dir, 'local.m3u8'));
    if (!await localM3u8.exists()) return false;

    return true;
  }

  Future<void> reset({
    bool deleteFiles = false,
    bool clearStore = false,
  }) async {
    await ensureInitialized();

    // 1) 停掉所有任务
    await scheduler.cancelAll(deleteFiles: deleteFiles);

    // 2) 清内存
    final all = _tasks.values.toList();
    _tasks.clear();

    _lastStatus.clear();
    _lastCompleted.clear();
    _lastDownloaded.clear();
    _lastRemuxBytes.clear();

    // 3) 清持久化（可选）
    if (clearStore) {
      // 最简单做法：逐个删除（你的 store 没有 clearAll，就这样）
      for (final t in all) {
        await store.deleteTask(t.taskId);
        _eventController.add(DownloadEvent(type: DownloadEventType.removed, task: t));
      }
    }
  }

  Future<void> dispose() async {
    if (!_inited) return;

    // 不强制 cancelAll，避免你想后台继续下载
    await _controller.close();
    await _eventController.close();

    _inited = false;
  }
}