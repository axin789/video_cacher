import 'task_status.dart';

/// 用于区分「未传参」与「显式传 null」的哨兵。
const Object _undefined = Object();

/// 下载任务记录，以 JSON 持久化。不含分片明细（从磁盘推导）。
class DownloadTask {
  /// 任务唯一 id（即 enqueue 传入的业务 id）。
  final String taskId;

  /// 业务侧影片 id（当前与 [taskId] 一致，保留字段）。
  final String movieId;

  /// 显示名，也用作存相册时的标题。
  final String name;

  /// 封面图地址（仅存储供 UI 使用，包内不下载）。
  final String coverImg;

  /// 下载地址。URL 刷新或 HLS 变体跳转后更新为最终生效的地址。
  final String url;

  /// 任务工作目录（分片、成片 mp4 都落在这里）。
  final String dir;

  /// 源类型（mp4 直链 / HLS）。mp4 任务嗅探到 m3u8 内容会被自动纠正为 hls。
  final SourceKind kind;

  /// 当前状态，见 [TaskStatus]。
  final TaskStatus status;

  /// 进度量纲随阶段变化（[progress] 恒为 0..1）：mp4 下载阶段为字节；
  /// HLS 下载阶段为分片数；remuxing 阶段为 remux 输入字节（第二段 0..1 进度）；
  /// completed 后回填为最终 mp4 文件字节数（终态单位真实）。
  final int totalBytes;

  /// 已完成量，量纲同 [totalBytes]。
  final int downloadedBytes;

  /// 成片 mp4 的本地绝对路径；completed 前为 null。
  final String? mp4Path;

  /// mp4 断点续传用的资源 ETag（HEAD 返回时即持久化，冷启动后仍可校验内容未变）。
  final String? etag;

  /// 完成后是否自动保存到系统相册。
  final bool saveToAlbum;

  /// 是否已成功保存到相册。
  final bool albumSaved;

  /// 最近一次相册保存的失败原因；非空后不再自动重试，仅可手动 copyToAlbum。
  final String? albumError;

  /// failed 时的错误信息；其余状态为 null。
  final String? error;

  /// 任务创建时间（epoch 毫秒）。
  final int createdAtMs;

  const DownloadTask({
    required this.taskId,
    required this.movieId,
    required this.name,
    required this.coverImg,
    required this.url,
    required this.dir,
    required this.kind,
    required this.createdAtMs,
    this.status = TaskStatus.queued,
    this.totalBytes = 0,
    this.downloadedBytes = 0,
    this.mp4Path,
    this.etag,
    this.saveToAlbum = true,
    this.albumSaved = false,
    this.albumError,
    this.error,
  });

  /// 下载进度 0..1；总长未知时为 0。
  double get progress =>
      totalBytes > 0 ? (downloadedBytes / totalBytes).clamp(0, 1) : 0;

  /// 是否已完成（completed）。
  bool get isFinished => status == TaskStatus.completed;

  /// 是否处于活动态（queued/running/remuxing）。
  bool get isActive =>
      status == TaskStatus.running ||
      status == TaskStatus.queued ||
      status == TaskStatus.remuxing;

  /// 复制并覆盖部分字段。可空字段（如 [mp4Path]、[error]）支持显式传 null 清空。
  DownloadTask copyWith({
    String? taskId,
    String? movieId,
    String? name,
    String? coverImg,
    String? url,
    String? dir,
    SourceKind? kind,
    TaskStatus? status,
    int? totalBytes,
    int? downloadedBytes,
    Object? mp4Path = _undefined,
    Object? etag = _undefined,
    bool? saveToAlbum,
    bool? albumSaved,
    Object? albumError = _undefined,
    Object? error = _undefined,
    int? createdAtMs,
  }) {
    return DownloadTask(
      taskId: taskId ?? this.taskId,
      movieId: movieId ?? this.movieId,
      name: name ?? this.name,
      coverImg: coverImg ?? this.coverImg,
      url: url ?? this.url,
      dir: dir ?? this.dir,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      mp4Path: identical(mp4Path, _undefined) ? this.mp4Path : mp4Path as String?,
      etag: identical(etag, _undefined) ? this.etag : etag as String?,
      saveToAlbum: saveToAlbum ?? this.saveToAlbum,
      albumSaved: albumSaved ?? this.albumSaved,
      albumError:
          identical(albumError, _undefined) ? this.albumError : albumError as String?,
      error: identical(error, _undefined) ? this.error : error as String?,
      createdAtMs: createdAtMs ?? this.createdAtMs,
    );
  }

  /// 序列化为 JSON（持久化用）。
  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'movieId': movieId,
        'name': name,
        'coverImg': coverImg,
        'url': url,
        'dir': dir,
        'kind': kind.name,
        'status': status.name,
        'totalBytes': totalBytes,
        'downloadedBytes': downloadedBytes,
        'mp4Path': mp4Path,
        'etag': etag,
        'saveToAlbum': saveToAlbum,
        'albumSaved': albumSaved,
        'albumError': albumError,
        'error': error,
        'createdAtMs': createdAtMs,
      };

  /// 从 JSON 恢复；缺失字段回退默认值，不抛异常。
  factory DownloadTask.fromJson(Map<String, dynamic> json) => DownloadTask(
        taskId: (json['taskId'] as String?) ?? '',
        movieId: (json['movieId'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        coverImg: (json['coverImg'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        dir: (json['dir'] as String?) ?? '',
        kind: SourceKind.fromName(json['kind'] as String?),
        status: TaskStatus.fromName(json['status'] as String?),
        totalBytes: (json['totalBytes'] as int?) ?? 0,
        downloadedBytes: (json['downloadedBytes'] as int?) ?? 0,
        mp4Path: json['mp4Path'] as String?,
        etag: json['etag'] as String?,
        saveToAlbum: (json['saveToAlbum'] as bool?) ?? true,
        albumSaved: (json['albumSaved'] as bool?) ?? false,
        albumError: json['albumError'] as String?,
        error: json['error'] as String?,
        createdAtMs: (json['createdAtMs'] as int?) ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DownloadTask &&
          runtimeType == other.runtimeType &&
          taskId == other.taskId &&
          movieId == other.movieId &&
          name == other.name &&
          coverImg == other.coverImg &&
          url == other.url &&
          dir == other.dir &&
          kind == other.kind &&
          status == other.status &&
          totalBytes == other.totalBytes &&
          downloadedBytes == other.downloadedBytes &&
          mp4Path == other.mp4Path &&
          etag == other.etag &&
          saveToAlbum == other.saveToAlbum &&
          albumSaved == other.albumSaved &&
          albumError == other.albumError &&
          error == other.error &&
          createdAtMs == other.createdAtMs;

  @override
  int get hashCode => Object.hash(
        taskId,
        movieId,
        name,
        coverImg,
        url,
        dir,
        kind,
        status,
        totalBytes,
        downloadedBytes,
        mp4Path,
        etag,
        saveToAlbum,
        albumSaved,
        albumError,
        error,
        createdAtMs,
      );

  @override
  String toString() =>
      'DownloadTask(taskId: $taskId, kind: ${kind.name}, status: ${status.name}, '
      'progress: ${progress.toStringAsFixed(2)})';
}
