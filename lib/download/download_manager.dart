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

  final _controller = StreamController<M3u8Task>.broadcast();
  Stream<M3u8Task> get taskStream => _controller.stream;
  Map<String, M3u8Task> get tasks => _tasks;

  /// 防止同一个任务“同时触发多次保存相册”
  final Set<String> _albumSaving = {};

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
      onTaskUpdate: (t) async {
        _tasks[t.taskId] = t;

        // 只 upsert 单条，避免频繁全量写
        await store.upsertTask(t);
        _controller.add(t);

        // 下载/转换完成后自动保存相册（HLS+MP4 都走这里）
        if(t.saveToAlbum){
          await _autoSaveToAlbumIfNeeded(t);
        }
      },
    );

    // 恢复历史任务
    final restored = await store.loadTasks();
    _tasks.addAll(restored);

    // 自动恢复 running/queued
    for (final t in _tasks.values) {
      if (t.status == TaskStatus.running || t.status == TaskStatus.queued) {
        scheduler.enqueue(t);
      }
    }

    _inited = true;
  }

  Future<void> _autoSaveToAlbumIfNeeded(M3u8Task t) async {
    // 只处理 completed
    if (t.status != TaskStatus.completed) return;

    // 必须有 mp4Path
    final mp4 = t.mp4Path;
    if (mp4 == null || mp4.isEmpty) return;

    // 已保存过就跳过
    if (t.albumSaved) return;

    // 防重入
    if (_albumSaving.contains(t.taskId)) return;
    _albumSaving.add(t.taskId);

    try {
      final f = File(mp4);
      if (!await f.exists()) {
        t.albumSaved = false;
        t.albumError = 'mp4 not exists';
        await store.upsertTask(t);
        _controller.add(t);
        return;
      }
      final len = await f.length();
      if (len <= 0) {
        t.albumSaved = false;
        t.albumError = 'mp4 is empty';
        await store.upsertTask(t);
        _controller.add(t);
        return;
      }

      // 保存相册（不影响任务完成状态）
      final ok = await AlbumSaver.saveVideo(mp4, title: t.name);
      if (ok) {
        t.albumSaved = true;
        t.albumError = null;
      } else {
        t.albumSaved = false;
        t.albumError = 'save album failed';
      }

      await store.upsertTask(t);
      _controller.add(t);
    } catch (e) {
      t.albumSaved = false;
      t.albumError = e.toString();
      await store.upsertTask(t);
      _controller.add(t);
    } finally {
      _albumSaving.remove(t.taskId);
    }
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

  void resumeById(String taskId) {
    final t = _tasks[taskId];
    if (t != null) scheduler.resume(t);
  }

  Future<void> cancel(String taskId, {bool deleteFiles = false}) async {
    await scheduler.cancel(taskId, deleteFiles: deleteFiles);
  }


  Future<void> deleteTaskById(String taskId) async {
    await ensureInitialized();
    final t = _tasks[taskId];
    if (t == null) return;

    try { await cancel(taskId, deleteFiles: false); } catch (_) {}

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

    //  3) 主动通知 UI：发一个“已删除/已取消”的事件（你也可以自定义 TaskStatus.deleted）
    t.status = TaskStatus.canceled;
    _controller.add(t);
  }
}