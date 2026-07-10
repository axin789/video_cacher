/// 下载引擎配置。不可变，带默认值。
class DownloadConfig {
  /// 最大并发任务数。
  final int maxConcurrency;

  /// 单任务内分片并发数（HLS）。
  final int segConcurrency;

  final Duration connectTimeout;
  final Duration receiveTimeout;
  final String userAgent;

  /// URL 刷新最大重试次数。
  final int refreshMaxRetries;

  /// URL 刷新退避间隔。
  final Duration refreshBackoff;

  const DownloadConfig({
    this.maxConcurrency = 3,
    this.segConcurrency = 2,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.userAgent = 'video_cacher/1.0',
    this.refreshMaxRetries = 3,
    this.refreshBackoff = const Duration(milliseconds: 500),
  });

  DownloadConfig copyWith({
    int? maxConcurrency,
    int? segConcurrency,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    String? userAgent,
    int? refreshMaxRetries,
    Duration? refreshBackoff,
  }) {
    return DownloadConfig(
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      segConcurrency: segConcurrency ?? this.segConcurrency,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      userAgent: userAgent ?? this.userAgent,
      refreshMaxRetries: refreshMaxRetries ?? this.refreshMaxRetries,
      refreshBackoff: refreshBackoff ?? this.refreshBackoff,
    );
  }
}
