/// 任务状态。持久化时以 [name] 字符串存储，不依赖枚举 index（重排易碎）。
enum TaskStatus {
  queued,
  running,
  remuxing,
  completed,
  paused,
  failed,
  canceled;

  /// 从名称解析，未知值回退为 [TaskStatus.queued]。
  static TaskStatus fromName(String? name) {
    for (final v in TaskStatus.values) {
      if (v.name == name) return v;
    }
    return TaskStatus.queued;
  }
}

/// 源类型。持久化时以 [name] 字符串存储。
enum SourceKind {
  mp4,
  hls;

  /// 从名称解析，未知值回退为 [SourceKind.mp4]。
  static SourceKind fromName(String? name) {
    for (final v in SourceKind.values) {
      if (v.name == name) return v;
    }
    return SourceKind.mp4;
  }
}
