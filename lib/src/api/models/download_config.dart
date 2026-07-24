/// 下载引擎配置。不可变，带默认值。
class DownloadConfig {
  /// 最大并发任务数。
  final int maxConcurrency;

  /// 单任务内分片并发数（HLS）。0.2.1 起解密后置到 remux，下载阶段是纯网络 IO，
  /// 适当提高并发可更充分利用带宽（默认 4）。
  final int segConcurrency;

  /// HTTP 连接超时。
  final Duration connectTimeout;

  /// HTTP 接收超时（两次数据到达的最大间隔）。
  final Duration receiveTimeout;

  /// 全部请求携带的 User-Agent。
  final String userAgent;

  /// 全部请求携带的自定义请求头（如 CDN 防盗链的 Referer）。
  /// 与 [userAgent] 合并，同名时以此处为准。
  final Map<String, String> headers;

  /// URL 刷新最大重试次数。
  final int refreshMaxRetries;

  /// URL 刷新退避间隔。
  final Duration refreshBackoff;

  /// 单次刷新回调超时：回调挂起超过此时长按该次尝试失败处理。
  final Duration refreshTimeout;

  /// 瞬时故障（连接/超时/5xx）的重试次数。
  /// 504 等网关超时通常需要数秒才恢复，故默认退避到秒级。
  final int transientMaxRetries;

  /// 瞬时故障重试的基础退避，按 1×/2×/4× 指数增长。
  final Duration transientBackoff;

  /// 视为「直链过期，需刷新 URL」的 HTTP 状态码。
  /// 部分 CDN 用 401/403 表示签名/token 过期，故默认全部纳入。
  final Set<int> refreshStatusCodes;

  const DownloadConfig({
    this.maxConcurrency = 3,
    this.segConcurrency = 4,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
    this.userAgent = 'video_cacher/1.0',
    this.headers = const {},
    this.refreshMaxRetries = 3,
    this.refreshBackoff = const Duration(milliseconds: 500),
    this.refreshTimeout = const Duration(seconds: 30),
    this.transientMaxRetries = 3,
    this.transientBackoff = const Duration(seconds: 1),
    this.refreshStatusCodes = const {401, 403, 404, 410},
  });

  /// 复制并覆盖部分字段。
  DownloadConfig copyWith({
    int? maxConcurrency,
    int? segConcurrency,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    String? userAgent,
    Map<String, String>? headers,
    int? refreshMaxRetries,
    Duration? refreshBackoff,
    Duration? refreshTimeout,
    int? transientMaxRetries,
    Duration? transientBackoff,
    Set<int>? refreshStatusCodes,
  }) {
    return DownloadConfig(
      maxConcurrency: maxConcurrency ?? this.maxConcurrency,
      segConcurrency: segConcurrency ?? this.segConcurrency,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      userAgent: userAgent ?? this.userAgent,
      headers: headers ?? this.headers,
      refreshMaxRetries: refreshMaxRetries ?? this.refreshMaxRetries,
      refreshBackoff: refreshBackoff ?? this.refreshBackoff,
      refreshTimeout: refreshTimeout ?? this.refreshTimeout,
      transientMaxRetries: transientMaxRetries ?? this.transientMaxRetries,
      transientBackoff: transientBackoff ?? this.transientBackoff,
      refreshStatusCodes: refreshStatusCodes ?? this.refreshStatusCodes,
    );
  }
}
