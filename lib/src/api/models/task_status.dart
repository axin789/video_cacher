/// 任务状态。持久化时以 [name] 字符串存储，不依赖枚举 index（重排易碎）。
enum TaskStatus {
  /// 已提交，等待并发槽位。
  queued,

  /// 下载中（mp4 收字节 / HLS 收分片）。
  running,

  /// HLS 分片下载完毕，正在转封装为 mp4（独立 isolate）。
  remuxing,

  /// 成片 mp4 已落地（终态，不可被 pause/cancel 降级）。
  completed,

  /// 已暂停，可 resume 断点续传。App 重启后未完成任务也统一落这里。
  paused,

  /// 出错终止，error 字段携带原因；可 resume 重试。
  failed,

  /// 已取消。
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
  /// mp4 直链。
  mp4,

  /// HLS（m3u8 播放列表 + TS 分片）。
  hls;

  /// 从名称解析，未知值回退为 [SourceKind.mp4]。
  static SourceKind fromName(String? name) {
    for (final v in SourceKind.values) {
      if (v.name == name) return v;
    }
    return SourceKind.mp4;
  }
}
