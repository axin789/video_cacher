/// 下载引擎配置。不可变，带默认值。
class DownloadConfig {
  /// 最大并发任务数。
  final int maxConcurrency;

  /// 单任务内分片并发数（HLS）。
  final int segConcurrency;

  /// HTTP 连接超时。
  final Duration connectTimeout;

  /// HTTP 接收超时（两次数据到达的最大间隔）。
  final Duration receiveTimeout;

  /// 全部请求携带的 User-Agent。
  final String userAgent;

  /// URL 刷新最大重试次数。
  final int refreshMaxRetries;

  /// URL 刷新退避间隔。
  final Duration refreshBackoff;

  /// 单次刷新回调超时：回调挂起超过此时长按该次尝试失败处理。
  final Duration refreshTimeout;

  const DownloadConfig({
    this.maxConcurrency = 3,
    this.segConcurrency = 2,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.userAgent = 'video_cacher/1.0',
    this.refreshMaxRetries = 3,
    this.refreshBackoff = const Duration(milliseconds: 500),
    this.refreshTimeout = const Duration(seconds: 30),
  });

  /// 复制并覆盖部分字段。
  DownloadConfig copyWith({
    int? maxConcurrency,
    int? segConcurrency,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    String? userAgent,
    int? refreshMaxRetries,
    Duration? refreshBackoff,
    Duration? refreshTimeout,
  }) {
    return DownloadConfig(
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      segConcurrency: segConcurrency ?? this.segConcurrency,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      userAgent: userAgent ?? this.userAgent,
      refreshMaxRetries: refreshMaxRetries ?? this.refreshMaxRetries,
      refreshBackoff: refreshBackoff ?? this.refreshBackoff,
      refreshTimeout: refreshTimeout ?? this.refreshTimeout,
    );
  }
}
