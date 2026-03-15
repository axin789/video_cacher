import 'task_store_base.dart';

// 条件导入，并统一使用 impl 别名
import 'task_store_io.dart' if (dart.library.html) 'task_store_web.dart'
    as impl;

// 对外统一工厂，实际调用实现文件里的函数
Future<TaskStore> openTaskStore() => impl.openTaskStore();
