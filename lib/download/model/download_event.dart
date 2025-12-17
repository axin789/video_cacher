import '../model/m3u8_models.dart';

enum DownloadEventType {
  taskAdded,
  taskUpdated,       // 任意字段更新（兜底）
  statusChanged,     // status 变化
  progress,          // completed/downloaded/remuxBytes 变化
  finished,          // completed/failed/canceled
  removed,           // deleteTaskById
}

class DownloadEvent {
  final DownloadEventType type;
  final M3u8Task task;
  final TaskStatus? fromStatus;
  final TaskStatus? toStatus;

  const DownloadEvent({
    required this.type,
    required this.task,
    this.fromStatus,
    this.toStatus,
  });

  bool get isFinished =>
      type == DownloadEventType.finished ||
          task.status == TaskStatus.completed ||
          task.status == TaskStatus.failed ||
          task.status == TaskStatus.canceled;
}