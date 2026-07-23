import 'download_task.dart';
import 'task_status.dart';

/// 对外事件快照，通过 broadcast stream 抛出，与内部 [DownloadTask] 解耦。
///
/// 纯进度事件按任务节流（约 10 次/秒），状态变更事件即时；
/// downloadedBytes/totalBytes 的量纲随阶段变化，见 [DownloadTask.totalBytes]。
class TaskEvent {
  /// 任务唯一 id。
  final String taskId;

  /// 事件发生时的任务状态。
  final TaskStatus status;

  /// 进度 0..1（总量未知时为 0）。remuxing 是独立的第二段 0..1。
  final double progress;

  /// 已完成量。量纲随阶段变化：mp4 下载为字节，HLS 下载为分片数，
  /// remuxing 为已喂入 remux 的输入字节，completed 回填为成片 mp4 字节数。
  final int downloadedBytes;

  /// 总量，量纲同 [downloadedBytes]；未知时为 0。
  final int totalBytes;

  /// failed 时的错误信息；其余状态为 null。
  final String? error;

  const TaskEvent({
    required this.taskId,
    required this.status,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    this.error,
  });

  /// 从任务记录截取事件快照。
  factory TaskEvent.fromTask(DownloadTask t) => TaskEvent(
        taskId: t.taskId,
        status: t.status,
        progress: t.progress,
        downloadedBytes: t.downloadedBytes,
        totalBytes: t.totalBytes,
        error: t.error,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TaskEvent &&
          runtimeType == other.runtimeType &&
          taskId == other.taskId &&
          status == other.status &&
          progress == other.progress &&
          downloadedBytes == other.downloadedBytes &&
          totalBytes == other.totalBytes &&
          error == other.error;

  @override
  int get hashCode => Object.hash(
        taskId,
        status,
        progress,
        downloadedBytes,
        totalBytes,
        error,
      );

  @override
  String toString() =>
      'TaskEvent(taskId: $taskId, status: ${status.name}, '
      'progress: ${progress.toStringAsFixed(2)})';
}
