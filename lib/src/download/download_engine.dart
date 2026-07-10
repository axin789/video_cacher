import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../api/models/download_config.dart';
import '../api/models/download_task.dart';
import '../api/models/task_event.dart';
import '../api/models/task_status.dart';
import '../log.dart';
import '../remux/remuxer.dart';
import '../store/task_store.dart';
import 'hls/hls_downloader.dart';
import 'mp4/mp4_downloader.dart';
import 'task_queue.dart';

/// 单任务的「待定意图」：一个活跃/收尾中的任务最近一次被要求做什么。
///
/// 合并了「取消 token 的原因」与「是否需要收尾后重排」两件事，保证二者不可能自相
/// 矛盾——最后一次显式操作（pause/cancel/resume）决定最终结果。
enum _Intent { none, pause, cancel, resume }

/// 下载编排核心：并发调度 + 状态机 + 事件广播 + 冷启动恢复。
///
/// 职责边界：
/// - 持有内存任务表 [_tasks]（唯一事实来源），每次变更同步写 [store] 并广播 [TaskEvent]。
/// - 用 [TaskQueue] 做并发闸门；`_run` 是单任务执行体，由闸门在腾出槽位时回调。
/// - pause/cancel/resume 通过单一 [_pendingIntent] 协作：token 被取消后，`_run` 的
///   catch 读它决定落到 paused / canceled；收尾 finally 读它决定是否重排（resume）。
class DownloadEngine {
  DownloadEngine({
    required TaskStore store,
    required Mp4Downloader mp4Downloader,
    required HlsDownloader hlsDownloader,
    required Remuxer remuxer,
    this.config = const DownloadConfig(),
  })  : _store = store,
        _mp4 = mp4Downloader,
        _hls = hlsDownloader,
        _remuxer = remuxer {
    _queue = TaskQueue(maxConcurrency: config.maxConcurrency, onStart: _run);
  }

  final TaskStore _store;
  final Mp4Downloader _mp4;
  final HlsDownloader _hls;
  final Remuxer _remuxer;
  final DownloadConfig config;

  late final TaskQueue _queue;

  final Map<String, DownloadTask> _tasks = {};
  final Map<String, CancelToken> _tokens = {};

  /// 每个活跃/收尾中任务的最近一次显式意图。见 [_Intent]。
  final Map<String, _Intent> _pendingIntent = {};

  /// MP4 续传用的 ETag：模型不落此字段，仅内存跟踪（冷启动后为空 → 从 0 或按 .part 续）。
  final Map<String, String?> _etags = {};

  final StreamController<TaskEvent> _events =
      StreamController<TaskEvent>.broadcast();

  bool _disposed = false;

  /// 内存任务表只读快照。
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  /// 对外事件流（广播）。
  Stream<TaskEvent> get events => _events.stream;

  /// 从存储加载全部任务。冷启动恢复：running/queued/remuxing 一律降级为 paused
  /// 并持久化（不自动续传），需用户显式 resume。
  Future<void> loadFromStore() async {
    final all = await _store.loadAll();
    for (final t in all) {
      if (t.status == TaskStatus.running ||
          t.status == TaskStatus.queued ||
          t.status == TaskStatus.remuxing) {
        final demoted = t.copyWith(status: TaskStatus.paused);
        _tasks[demoted.taskId] = demoted;
        await _store.upsert(demoted);
        _emit(demoted);
      } else {
        _tasks[t.taskId] = t;
      }
    }
  }

  /// 提交新任务（或对未完成的已存在任务视为 resume）：登记 → 置 queued → 入队。
  void submit(DownloadTask task) {
    if (_disposed) return;
    final existing = _tasks[task.taskId];
    if (existing != null && existing.isFinished) return;
    if (_queue.contains(task.taskId)) return; // 已在运行/等待，忽略重复提交
    final base = existing ?? task;
    _commit(base.copyWith(status: TaskStatus.queued, error: null));
    _queue.add(task.taskId);
  }

  /// 继续 paused/failed/queued 的任务。
  void resume(String taskId) {
    if (_disposed) return;
    final task = _tasks[taskId];
    if (task == null) return;
    final resumable = task.status == TaskStatus.paused ||
        task.status == TaskStatus.failed ||
        task.status == TaskStatus.queued;
    if (!resumable) return;
    if (_queue.isActive(taskId)) {
      // 仍在收尾（暂停中）：登记待恢复，收尾后由 _run 的 finally 自动重排。
      _pendingIntent[taskId] = _Intent.resume;
      return;
    }
    if (_queue.isQueued(taskId)) return; // 已在等待队列
    _commit(task.copyWith(status: TaskStatus.queued, error: null));
    _queue.add(taskId);
  }

  /// 暂停：登记意图（压过任何待定 resume）→ 活跃则取消 token / 停 remux，等待则出队 → 置 paused。
  void pause(String taskId) {
    if (_disposed) return;
    final task = _tasks[taskId];
    if (task == null) return;
    _pendingIntent[taskId] = _Intent.pause;
    _interrupt(task);
    _commit(task.copyWith(status: TaskStatus.paused));
  }

  /// 取消：登记意图（压过任何待定 resume）→ 取消 token / 停 remux / 出队 → 置 canceled，可选删目录。
  Future<void> cancel(String taskId, {bool deleteFiles = false}) async {
    if (_disposed) return;
    final task = _tasks[taskId];
    if (task == null) return;
    _pendingIntent[taskId] = _Intent.cancel;
    _interrupt(task);
    _commit(task.copyWith(status: TaskStatus.canceled));
    if (deleteFiles) {
      try {
        final d = Directory(task.dir);
        if (await d.exists()) await d.delete(recursive: true);
      } catch (_) {
        // 删除失败不影响取消语义。
      }
    }
  }

  /// 中断一个活跃任务：下载阶段取消 CancelToken；remux 阶段额外调 remuxer.cancel（软停）。
  /// 若任务只在等待队列则直接出队。
  void _interrupt(DownloadTask task) {
    final id = task.taskId;
    if (_queue.isActive(id)) {
      _tokens[id]?.cancel();
      if (task.status == TaskStatus.remuxing) _remuxer.cancel(id);
    } else {
      _queue.remove(id);
    }
  }

  /// 删除任务：中断（若活跃）→ 出队 → 移出内存表 → 删持久化记录 → 广播 canceled
  /// 事件（UI 以 tasks 表重建列表，移除后即刻消失，无需等重启）。
  ///
  /// 不走 [_commit]（避免再写一次存储与 [_store.delete] 竞争复活已删文件）；
  /// 活跃 worker 之后的提交因任务已不在 [_tasks] 而被跳过，不会复活。
  Future<void> remove(String taskId) async {
    if (_disposed) return;
    final task = _tasks[taskId];
    if (task == null) return;
    _pendingIntent[taskId] = _Intent.cancel;
    _interrupt(task);
    _tasks.remove(taskId);
    _etags.remove(taskId);
    await _store.delete(taskId);
    VideoCacherLog.d('engine', 'task $taskId: ${task.status.name} -> 已删除');
    _emit(task.copyWith(status: TaskStatus.canceled));
  }

  /// 把等待中的任务移到队首。
  void prioritize(String taskId) => _queue.prioritize(taskId);

  /// 回写相册保存结果（仅更新 albumSaved/albumError，不动任务状态）。
  /// 供门面的自动/手动存相册在保存完成后调用。
  void setAlbumResult(String taskId, {required bool saved, String? error}) {
    if (_disposed) return;
    final task = _tasks[taskId];
    if (task == null) return;
    _commit(task.copyWith(albumSaved: saved, albumError: error));
  }

  /// 调整并发上限（只更新闸门并泵，不重建引擎）。
  Future<void> setMaxConcurrency(int n) async {
    _queue.setMaxConcurrency(n < 1 ? 1 : n);
  }

  /// 释放：取消全部活跃 token、关闭存储与事件流。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final t in _tokens.values) {
      t.cancel();
    }
    _tokens.clear();
    _pendingIntent.clear();
    await _store.close();
    await _events.close();
  }

  /// 单任务执行体，由 [TaskQueue] 在腾出并发槽时回调。
  Future<void> _run(String taskId) async {
    if (_disposed) return; // dispose 前已排入的 pump microtask 到此为止。
    final token = CancelToken();
    _tokens[taskId] = token;
    // 一次真正的运行开始：清空上一轮遗留的意图。
    _pendingIntent[taskId] = _Intent.none;

    try {
      final task = _tasks[taskId];
      if (task == null) return;
      _commit(task.copyWith(status: TaskStatus.running, error: null));

      if (task.kind == SourceKind.mp4) {
        await _runMp4(taskId, task, token);
      } else {
        await _runHls(taskId, task, token);
      }
    } catch (e) {
      final cur = _tasks[taskId];
      if (cur != null) {
        if (_isCancellation(e)) {
          // 取消不算失败：cancel 意图落 canceled，其余（pause/resume/none）落 paused，
          // resume 的重排在 finally 处理。
          final intent = _pendingIntent[taskId] ?? _Intent.pause;
          _commit(cur.copyWith(
            status: intent == _Intent.cancel
                ? TaskStatus.canceled
                : TaskStatus.paused,
          ));
        } else {
          _commit(cur.copyWith(status: TaskStatus.failed, error: e.toString()));
        }
      }
    } finally {
      _tokens.remove(taskId);
      final pending = _pendingIntent[taskId] ?? _Intent.none;
      _queue.onDone(taskId); // 归还槽位，泵下一个
      final cur = _tasks[taskId];
      if (pending == _Intent.resume && !_disposed && cur != null) {
        // 暂停中收到过 resume（且未被随后的 pause/cancel 压过）：收尾后重排。
        _pendingIntent[taskId] = _Intent.none;
        _commit(cur.copyWith(status: TaskStatus.queued, error: null));
        _queue.add(taskId);
      } else {
        _pendingIntent.remove(taskId);
      }
    }
  }

  Future<void> _runMp4(
      String taskId, DownloadTask task, CancelToken token) async {
    final dest = p.join(task.dir, 'video.mp4');
    final result = await _mp4.download(
      taskId: taskId,
      url: task.url,
      destPath: dest,
      knownEtag: _etags[taskId],
      onProgress: (d, t) => _onProgress(taskId, d, t),
      cancelToken: token,
    );
    _etags[taskId] = result.etag;
    final cur = _tasks[taskId];
    if (cur == null) return;
    _commit(cur.copyWith(
      status: TaskStatus.completed,
      mp4Path: result.mp4Path,
      url: result.finalUrl,
      totalBytes: result.totalBytes,
      downloadedBytes: result.totalBytes,
      error: null,
    ));
  }

  Future<void> _runHls(
      String taskId, DownloadTask task, CancelToken token) async {
    final result = await _hls.download(
      taskId: taskId,
      entryUrl: task.url,
      dir: task.dir,
      onProgress: (done, total) => _onProgress(taskId, done, total),
      cancelToken: token,
    );
    var cur = _tasks[taskId];
    if (cur == null) return;
    _commit(cur.copyWith(
      status: TaskStatus.remuxing,
      url: result.finalEntryUrl,
    ));

    final outMp4 = p.join(task.dir, 'video.mp4');
    final res = await _remuxer.remux(
      taskId: taskId,
      segmentFiles: result.segmentFiles,
      outMp4: outMp4,
      dir: task.dir,
    );

    // remux 不吃 CancelToken，取消经 _remuxer.cancel(taskId) 软停。返回后必须重读
    // 当前状态/意图：期间被 pause/cancel 过就尊重该终态，绝不用 completed 覆盖。
    cur = _tasks[taskId];
    if (cur == null) return;
    final pending = _pendingIntent[taskId] ?? _Intent.none;
    if (cur.status == TaskStatus.canceled || pending == _Intent.cancel) return;
    if (cur.status == TaskStatus.paused || pending == _Intent.pause) return;

    if (res.ok) {
      final finalMp4 = res.outMp4 ?? outMp4;
      await _remuxer.cleanup(dir: task.dir, outMp4: finalMp4, success: true);
      _commit(cur.copyWith(
        status: TaskStatus.completed,
        mp4Path: finalMp4,
        error: null,
      ));
    } else {
      _commit(cur.copyWith(
        status: TaskStatus.failed,
        error: res.error ?? 'remux failed',
      ));
    }
  }

  /// 进度回调：只更新内存 + upsert（存储自带去抖，不会写盘风暴）+ 广播事件。
  void _onProgress(String taskId, int downloaded, int total) {
    final cur = _tasks[taskId];
    if (cur == null) return;
    _commit(cur.copyWith(
      downloadedBytes: downloaded,
      totalBytes: total > 0 ? total : cur.totalBytes,
    ));
  }

  /// 提交一次任务变更：写内存 → upsert（状态变更立即刷盘、纯进度去抖）→ 广播。
  void _commit(DownloadTask next) {
    // 只记录状态迁移（纯进度更新不打，避免刷屏）；失败附带原因。
    final prev = _tasks[next.taskId];
    if (prev == null || prev.status != next.status) {
      VideoCacherLog.d(
          'engine',
          'task ${next.taskId}: ${prev?.status.name ?? 'new'} -> '
          '${next.status.name}'
          '${next.status == TaskStatus.failed ? ' | ${next.error}' : ''}');
    }
    _tasks[next.taskId] = next;
    // 忽略写入错误：dispose 关闭 store 后仍可能有活跃 worker 触发 upsert，
    // 真实 store（如 sqlite）会抛，这里吞掉避免未捕获的异步异常。
    _store.upsert(next).ignore();
    _emit(next);
  }

  void _emit(DownloadTask t) {
    if (!_events.isClosed) _events.add(TaskEvent.fromTask(t));
  }

  /// 只识别 dio 的取消型异常（CancelToken 触发）。HLS/remux 层若以非 dio 异常表达
  /// 取消，会被归类为 failed——当前所有下载路径的取消都经 dio CancelToken，成立。
  bool _isCancellation(Object e) =>
      e is DioException && e.type == DioExceptionType.cancel;
}
