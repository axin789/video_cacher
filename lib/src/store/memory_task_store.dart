import '../api/models/download_task.dart';
import 'task_store.dart';

/// 纯内存实现，无持久化。用于 web 端与单元测试。
class MemoryTaskStore implements TaskStore {
  final Map<String, DownloadTask> _tasks = {};

  @override
  Future<List<DownloadTask>> loadAll() async => _tasks.values.toList();

  @override
  Future<void> upsert(DownloadTask task) async {
    _tasks[task.taskId] = task;
  }

  @override
  Future<void> delete(String taskId) async {
    _tasks.remove(taskId);
  }

  @override
  Future<void> close() async {
    _tasks.clear();
  }
}
