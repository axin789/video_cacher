import '../api/models/download_task.dart';

/// 任务存储抽象。负责下载任务记录的持久化读写。
///
/// 具体实现可用内存、JSON 文件等；上层只依赖此接口。
abstract class TaskStore {
  /// 加载全部任务记录，顺序不保证。
  Future<List<DownloadTask>> loadAll();

  /// 按 taskId 插入或整条替换（insert-or-replace）。
  Future<void> upsert(DownloadTask task);

  /// 按 taskId 删除；不存在则忽略。
  Future<void> delete(String taskId);

  /// 释放资源 / 刷盘。允许空实现。
  Future<void> close();
}
