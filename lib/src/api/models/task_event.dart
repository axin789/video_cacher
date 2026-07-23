import 'download_task.dart';
import 'task_status.dart';

/// 对外事件快照，通过 broadcast stream 抛出，与内部 [DownloadTask] 解耦。
///
/// 纯进度事件按任务节流（约 10 次/秒），状态变更事件即时；
/// downloadedBytes/totalBytes 的量纲随阶段变化，见 [DownloadTask.totalBytes]。
class TaskEvent {
  final String taskId;
  final TaskStatus status;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
  final String? error;

  const TaskEvent({
    required this.taskId,
    required this.status,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
    this.error,
  });

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
