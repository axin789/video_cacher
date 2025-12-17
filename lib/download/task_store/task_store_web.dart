import 'package:flutter/foundation.dart';

import '../download_library.dart';
import 'task_store_base.dart';

class TaskStoreWeb implements TaskStore {
  @override
  Future<void> deleteTask(String id) async {
    debugPrint('WEB不支持下载');
  }

  @override
  Future<Map<String, M3u8Task>> loadTasks() async {
    debugPrint('WEB不支持下载');
    return {};
  }

  @override
  Future<void> saveTasks(Map<String, M3u8Task> tasks) async {
    debugPrint('WEB不支持下载');
  }

  @override
  Future<void> upsertTask(M3u8Task task) async {
    debugPrint('WEB不支持下载');
  }
}
Future<TaskStore> openTaskStore()async{
  return TaskStoreWeb();
}
