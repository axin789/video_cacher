

import '../download_library.dart';

abstract class TaskStore {

  Future<void> saveTasks(Map<String, M3u8Task> tasks);

  Future<Map<String, M3u8Task>> loadTasks();

  Future<void> upsertTask(M3u8Task task);

  Future<void> deleteTask(String id);
}
