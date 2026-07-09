import 'dart:async';

/// 由引擎注入的启动回调：队列腾出并发槽时，用它去 START 一个 taskId。
typedef StartTask = void Function(String taskId);

/// 通用并发闸门：FIFO 等待队列 + 运行中集合 + 上限 [maxConcurrency]。
///
/// 只认 taskId 与启动回调，不耦合任何业务模型。用一个微任务泵 [_drain] 驱动：
/// 有空槽且队列非空时，从队首取出置入 [_active] 并回调 [_start]。任务真正结束由
/// 引擎调用 [onDone] 归还槽位并再次泵。
class TaskQueue {
  TaskQueue({required int maxConcurrency, required StartTask onStart})
      : _max = maxConcurrency < 1 ? 1 : maxConcurrency,
        _start = onStart;

  final StartTask _start;
  int _max;

  final List<String> _queue = <String>[]; // 等待中，FIFO
  final Set<String> _active = <String>{}; // 运行中
  bool _pumpScheduled = false;

  int get maxConcurrency => _max;

  /// 运行中任务数。
  int get activeCount => _active.length;

  bool isActive(String taskId) => _active.contains(taskId);

  bool isQueued(String taskId) => _queue.contains(taskId);

  /// 在队列或运行中（即已被本闸门接管）。
  bool contains(String taskId) =>
      _active.contains(taskId) || _queue.contains(taskId);

  /// 入队等待。已在队列或运行中则忽略，避免重复。
  void add(String taskId) {
    if (contains(taskId)) return;
    _queue.add(taskId);
    _schedulePump();
  }

  /// 从等待队列移除（仅等待中有效）；运行中的任务不受影响。
  /// 返回是否确实从队列里移除了。
  bool remove(String taskId) => _queue.remove(taskId);

  /// 把等待中的任务移到队首优先执行；不在等待队列则无效。
  void prioritize(String taskId) {
    if (_queue.remove(taskId)) {
      _queue.insert(0, taskId);
      _schedulePump();
    }
  }

  /// 引擎在任务真正结束（完成/失败/取消/暂停）后调用，归还槽位并泵下一个。
  void onDone(String taskId) {
    _active.remove(taskId);
    _schedulePump();
  }

  /// 调整并发上限并泵（不重建实例）。上限下调不会中断已在运行的任务，
  /// 只是短时超额，随任务结束自然收敛。
  void setMaxConcurrency(int n) {
    _max = n < 1 ? 1 : n;
    _schedulePump();
  }

  /// 主动触发一次泵。
  void pump() => _schedulePump();

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _drain();
    });
  }

  void _drain() {
    while (_active.length < _max && _queue.isNotEmpty) {
      final id = _queue.removeAt(0);
      _active.add(id);
      _start(id);
    }
  }
}
