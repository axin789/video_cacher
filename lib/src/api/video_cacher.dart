import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../album/album_saver.dart';
import '../download/download_engine.dart';
import '../download/hls/hls_downloader.dart';
import '../download/http/http_client.dart';
import '../download/http/url_refresher.dart';
import '../download/mp4/mp4_downloader.dart';
import '../download/source_detector.dart';
import '../remux/dart_transmuxer/dart_transmuxer.dart';
import '../remux/remuxer.dart';
import '../store/json_task_store.dart';
import 'models/download_config.dart';
import 'models/download_task.dart';
import 'models/task_event.dart';
import 'models/task_status.dart';

/// 插件对外唯一门面（单例）。串起 HTTP → 下载 → remux → 存储 → 事件 全链路，
/// 并在任务完成时自动存相册。
class VideoCacher {
  VideoCacher._();

  static final VideoCacher instance = VideoCacher._();

  bool _inited = false;

  /// 初始化在飞 Future：并发调用共享同一次初始化，防止双重装配。
  Future<void>? _initFuture;

  late HttpClient _http;
  late UrlRefresher _refresher;
  late JsonTaskStore _store;
  late DownloadEngine _engine;
  late Mp4Downloader _mp4;
  late HlsDownloader _hls;
  late SourceDetector _detector;
  late Remuxer _remuxer;
  late Directory _baseDir;

  /// 插件工作根目录：`<appDocs>/video_cacher`。
  late String _rootDir;

  /// setRefreshUrl 若在 init 前调用，先缓存，init 时应用到刷新器。
  Future<String> Function(String id)? _pendingRefresh;
  bool _refreshPending = false;

  /// 自动存相册去重：正在保存的 taskId 集合，防并发双存。
  final Set<String> _albumSaving = <String>{};

  StreamSubscription<TaskEvent>? _eventSub;

  /// 幂等初始化。默认取应用文档目录为根，装配全链路并加载既有任务。
  /// 并发调用共享同一次初始化，config 以第一个调用者为准。
  Future<void> ensureInitialized({DownloadConfig config = const DownloadConfig()}) =>
      _initFuture ??= _doInit(config);

  Future<void> _doInit(DownloadConfig config) async {
    _baseDir = await getApplicationDocumentsDirectory();
    _rootDir = p.join(_baseDir.path, 'video_cacher');

    _http = HttpClient(config);
    _refresher = UrlRefresher(
      maxRetries: config.refreshMaxRetries,
      backoff: config.refreshBackoff,
      timeout: config.refreshTimeout,
    );
    if (_refreshPending) {
      _refresher.callback = _pendingRefresh;
      _refreshPending = false;
      _pendingRefresh = null;
    }

    _mp4 = Mp4Downloader(http: _http, refresher: _refresher);
    _hls = HlsDownloader(
      http: _http,
      refresher: _refresher,
      segConcurrency: config.segConcurrency,
    );
    _detector = SourceDetector(_http);
    _remuxer = DartTransmuxer();
    _store = JsonTaskStore(_rootDir);
    _engine = DownloadEngine(
      store: _store,
      mp4Downloader: _mp4,
      hlsDownloader: _hls,
      remuxer: _remuxer,
      config: config,
    );

    await _engine.loadFromStore();

    _eventSub = _engine.events.listen(_onEvent);

    _inited = true;
  }

  /// 注入 URL 刷新回调。init 前后调用都安全。
  void setRefreshUrl(Future<String> Function(String id)? fn) {
    if (_inited) {
      _refresher.callback = fn;
    } else {
      _pendingRefresh = fn;
      _refreshPending = true;
    }
  }

  /// 对外任务事件流。
  Stream<TaskEvent> get taskStream => _engine.events;

  /// 内存任务表只读快照。
  Map<String, DownloadTask> get tasks => _engine.tasks;

  /// 提交或续传一个下载任务。已存在且未完成 → 续传；否则识别源类型后新建提交。
  Future<DownloadTask> enqueue({
    required String id,
    required String name,
    required String cover,
    required String url,
    bool saveToAlbum = true,
  }) async {
    await ensureInitialized();

    final existing = _engine.tasks[id];
    if (existing != null && !existing.isFinished) {
      _engine.resume(id);
      return existing;
    }

    final kind = await _detector.detect(url);
    final task = DownloadTask(
      taskId: id,
      movieId: id,
      name: name,
      coverImg: cover,
      url: url,
      dir: p.join(_rootDir, 'tasks_data', id),
      kind: kind,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      saveToAlbum: saveToAlbum,
    );
    _engine.submit(task);
    return task;
  }

  void pause(String id) => _engine.pause(id);

  void resume(String id) => _engine.resume(id);

  Future<void> cancel(String id, {bool deleteFiles = false}) =>
      _engine.cancel(id, deleteFiles: deleteFiles);

  void prioritize(String id) => _engine.prioritize(id);

  Future<void> setMaxConcurrency(int n) => _engine.setMaxConcurrency(n);

  /// 删除任务：引擎侧移除（中断 + 出内存表 + 删存储记录）→ 删任务目录。
  Future<void> deleteTask(String id) async {
    final task = _engine.tasks[id];
    await _engine.remove(id);
    if (task != null) {
      try {
        final d = Directory(task.dir);
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {
        // 删目录失败不影响删除语义。
      }
    }
  }

  Future<void> dispose() async {
    await _eventSub?.cancel();
    _eventSub = null;
    // 先停引擎（取消 token，任务落 paused/canceled），再关 HTTP 层，避免在途请求被判 failed。
    await _engine.dispose();
    _http.close();
    _inited = false;
    _initFuture = null;
  }

  /// 手动把某任务的 mp4 存相册。
  Future<AlbumSaveResult> copyToAlbum(String id) async {
    final task = _engine.tasks[id];
    final path = task?.mp4Path;
    if (task == null || path == null || path.isEmpty) {
      return const AlbumSaveResult(false, '任务无可保存的 mp4');
    }
    final r = await AlbumSaver.saveVideo(path, title: task.name);
    _engine.setAlbumResult(id, saved: r.ok, error: r.error);
    return r;
  }

  /// 手动保存任意本地视频到相册（不关联任务）。
  Future<AlbumSaveResult> copyPathToAlbum(String path, {String? title}) =>
      AlbumSaver.saveVideo(path, title: title);

  /// 自动存相册准入判定：需要存、未存过、且从未失败过。
  /// 首次失败后 albumError 非空即不再自动重试（setAlbumResult 会再广播一次
  /// completed 事件，不挡会形成无限重试环），此后只能手动 copyToAlbum。
  @visibleForTesting
  static bool shouldAutoSave(DownloadTask task) {
    if (!task.saveToAlbum || task.albumSaved) return false;
    if (task.albumError != null) return false;
    final path = task.mp4Path;
    return path != null && path.isNotEmpty;
  }

  /// 监听引擎事件，驱动「完成即自动存相册」。
  void _onEvent(TaskEvent e) {
    if (e.status != TaskStatus.completed) return;
    final task = _engine.tasks[e.taskId];
    if (task == null) return;
    if (!shouldAutoSave(task)) return;
    if (_albumSaving.contains(task.taskId)) return;

    _albumSaving.add(task.taskId);
    // 存相册失败只记 albumError，绝不改动任务的 completed 状态。
    unawaited(() async {
      try {
        final r = await AlbumSaver.saveVideo(task.mp4Path!, title: task.name);
        _engine.setAlbumResult(task.taskId, saved: r.ok, error: r.error);
      } finally {
        _albumSaving.remove(task.taskId);
      }
    }());
  }
}
