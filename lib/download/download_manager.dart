import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'download_scheduler.dart';
import 'local_video_server.dart';
import 'model/m3u8_models.dart';
import 'processor/android_remux_post_processor.dart';
import 'processor/ios_post_processor.dart';
import 'processor/post_processor.dart';
import 'task_store/task_store.dart';
import 'task_store/task_store_base.dart';
import 'utils/save_video_to_album.dart';
import 'utils/source_detector.dart';

typedef RefreshUrl = Future<String> Function(String id);

class DownloadManager {
  DownloadManager._();
  static final DownloadManager instance = DownloadManager._();

  bool _inited = false;

  late Dio dio;
  late DownloadScheduler scheduler;
  late final TaskStore store;
  Directory? baseDir;
  late final PostProcessor _postProcessor;
  final Map<String, M3u8Task> _tasks = {};
  RefreshUrl? _refreshUrl;

  final _controller = StreamController<M3u8Task>.broadcast();
  Stream<M3u8Task> get taskStream => _controller.stream;
  Map<String, M3u8Task> get tasks => _tasks;

  /// 防止同一个任务“同时触发多次保存相册”
  final Set<String> _albumSaving = {};

  /// 业务方注入：URL 失效（如 404）时按 id 刷新下载地址
  void setRefreshUrl(RefreshUrl? fn) {
    _refreshUrl = fn;
    if (_inited) {
      scheduler.refreshUrl = fn;
    }
  }

  Future<void> ensureInitialized() async {
    if (_inited) return;

    if (Platform.isIOS) {
      await LocalVideoServer().ensureRunning();
      _postProcessor = IosPostProcessor();
    } else {
      _postProcessor = AndroidRemuxPostProcessor();
    }

    baseDir = await getApplicationDocumentsDirectory();

    store = await openTaskStore();

    dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'm3u8/2.0'},
      ),
    );

    scheduler = DownloadScheduler(
      dio: dio,
      maxActiveVideos: 3,
      postProcessor: _postProcessor,
      refreshUrl: _refreshUrl,
      onTaskUpdate: (t) async {
        _tasks[t.taskId] = t;

        // 只增量更新单条任务，避免频繁全量写入
        await store.upsertTask(t);
        _controller.add(t);

        // 下载或转换完成后自动保存到相册（HLS 和 MP4 都走这里）
        if (t.saveToAlbum) {
          await _autoSaveToAlbumIfNeeded(t);
        }
      },
    );

    // 恢复历史任务
    final restored = await store.loadTasks();
    _tasks.addAll(restored);

    // 进程被杀后，持久化中的运行态已不可信。
    // 冷启动时统一转成 paused，要求用户手动继续，避免静默自动续传
    for (final t in _tasks.values) {
      if (t.status == TaskStatus.running ||
          t.status == TaskStatus.queued ||
          t.status == TaskStatus.postProcessing) {
        t.status = TaskStatus.paused;
        await store.upsertTask(t);
      }
    }

    _inited = true;
  }

  Future<AlbumSaveResult> _autoSaveToAlbumIfNeeded(M3u8Task t) async {
    // 只处理 completed 状态
    if (t.status != TaskStatus.completed) {
      return const AlbumSaveResult(false, 'task not completed');
    }

    // 必须已经有 mp4Path
    final mp4 = t.mp4Path;
    if (mp4 == null || mp4.isEmpty) {
      return const AlbumSaveResult(false, 'mp4 path is empty');
    }

    // 已保存过就跳过
    if (t.albumSaved) return const AlbumSaveResult(true);

    // 防重入
    if (_albumSaving.contains(t.taskId)) {
      return const AlbumSaveResult(false, 'album save in progress');
    }
    _albumSaving.add(t.taskId);

    try {
      final f = File(mp4);
      if (!await f.exists()) {
        t.albumSaved = false;
        t.albumError = 'mp4 not exists';
        await store.upsertTask(t);
        _controller.add(t);
        return AlbumSaveResult(false, t.albumError);
      }
      final len = await f.length();
      if (len <= 0) {
        t.albumSaved = false;
        t.albumError = 'mp4 is empty';
        await store.upsertTask(t);
        _controller.add(t);
        return AlbumSaveResult(false, t.albumError);
      }

      // 保存相册（不影响任务完成状态）
      final r = await AlbumSaver.saveVideoWithResult(mp4, title: t.name);
      if (r.ok) {
        t.albumSaved = true;
        t.albumError = null;
      } else {
        t.albumSaved = false;
        t.albumError = r.error ?? 'save album failed';
      }

      await store.upsertTask(t);
      _controller.add(t);
      return AlbumSaveResult(t.albumSaved, t.albumError);
    } catch (e) {
      t.albumSaved = false;
      t.albumError = e.toString();
      await store.upsertTask(t);
      _controller.add(t);
      return AlbumSaveResult(false, t.albumError);
    } finally {
      _albumSaving.remove(t.taskId);
    }
  }

  Future<M3u8Task> enqueue({
    required String id,
    required String name,
    required String cover,
    required String url,
    bool saveToAlbum = true,
  }) {
    return addOrResumeFormMeta(
      taskId: id,
      movieId: id,
      lid: id,
      name: name,
      coverImg: cover,
      url: url,
      saveToAlbum: saveToAlbum,
    );
  }

  Future<M3u8Task> addOrResumeFormMeta({
    required String taskId,
    required String movieId,
    required String lid,
    required String name,
    required String coverImg,
    required String url,
    bool saveToAlbum = true,
  }) async {
    await ensureInitialized();

    final dir = p.join(baseDir!.path, 'm3u8_task', taskId);

    if (_tasks.containsKey(taskId)) {
      final t = _tasks[taskId]!;
      t.saveToAlbum = saveToAlbum;
      await store.upsertTask(t);
      if (!t.isFinished) scheduler.resume(t);
      return t;
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
      saveToAlbum: saveToAlbum,
    );

    _tasks[taskId] = task;
    scheduler.enqueue(task);
    await store.upsertTask(task);
    return task;
  }

  void pause(String taskId) => scheduler.pause(taskId);

  Future<void> setMaxConcurrency(int n) async {
    await ensureInitialized();
    if (n < 1) return;
    scheduler = DownloadScheduler(
      dio: dio,
      maxActiveVideos: n,
      postProcessor: _postProcessor,
      refreshUrl: _refreshUrl,
      onTaskUpdate: (t) async {
        _tasks[t.taskId] = t;
        await store.upsertTask(t);
        _controller.add(t);
        if (t.saveToAlbum) {
          await _autoSaveToAlbumIfNeeded(t);
        }
      },
    );
    for (final t in _tasks.values) {
      if (!t.isFinished && t.status != TaskStatus.paused) {
        scheduler.enqueue(t);
      }
    }
  }

  void resumeById(String taskId) {
    final t = _tasks[taskId];
    if (t != null) scheduler.resume(t);
  }

  Future<bool> retryFailedTaskById(String taskId, {String? overrideUrl}) async {
    await ensureInitialized();
    final t = _tasks[taskId];
    if (t == null) return false;
    if (t.status != TaskStatus.failed) {
      scheduler.resume(t);
      return true;
    }

    final preferredUrl = overrideUrl?.trim();
    if (preferredUrl != null && preferredUrl.isNotEmpty) {
      t.url = preferredUrl;
    } else if (_refreshUrl != null) {
      final newUrl = (await _refreshUrl!(taskId)).trim();
      if (newUrl.isEmpty) {
        t.error = 'refresh url is empty';
        await store.upsertTask(t);
        _controller.add(t);
        return false;
      }
      t.url = newUrl;
    }

    t.error = null;
    scheduler.resume(t);
    await store.upsertTask(t);
    _controller.add(t);
    return true;
  }

  Future<void> cancel(String taskId, {bool deleteFiles = false}) async {
    await scheduler.cancel(taskId, deleteFiles: deleteFiles);
  }

  Future<bool> copyToAlbum(String taskId) async {
    final r = await copyToAlbumWithResult(taskId);
    return r.ok;
  }

  Future<AlbumSaveResult> copyToAlbumWithResult(String taskId) async {
    await ensureInitialized();
    final t = _tasks[taskId];
    if (t == null) return const AlbumSaveResult(false, 'task not found');
    return _autoSaveToAlbumIfNeeded(t);
  }

  Future<bool> copyPathToAlbum(String mp4Path, {String? title}) {
    return copyPathToAlbumWithResult(mp4Path, title: title).then((r) => r.ok);
  }

  Future<AlbumSaveResult> copyPathToAlbumWithResult(String mp4Path,
      {String? title}) {
    return AlbumSaver.saveVideoWithResult(mp4Path, title: title);
  }

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

    //  1) 内存移除
    _tasks.remove(taskId);

    //  2) 持久化移除
    await store.deleteTask(taskId);

    // 3) 主动通知 UI：发出“已删除/已取消”事件（也可以自行扩展 TaskStatus.deleted）
    t.status = TaskStatus.canceled;
    _controller.add(t);
  }
}
