import 'task_store_base.dart';

// 条件导入 + 起别名 impl
import 'task_store_io.dart'
if (dart.library.html) 'task_store_web.dart' as impl;

// 对外统一工厂，实际调用实现文件里的函数
Future<TaskStore> openTaskStore() => impl.openTaskStore();
