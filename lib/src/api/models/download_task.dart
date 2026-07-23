import 'task_status.dart';

/// 用于区分「未传参」与「显式传 null」的哨兵。
const Object _undefined = Object();

/// 内部任务记录，以 JSON 持久化。不含分片明细（从磁盘推导）。
class DownloadTask {
  final String taskId;
  final String movieId;
  final String name;
  final String coverImg;
  final String url;
  final String dir;
  final SourceKind kind;
  final TaskStatus status;

  /// 进度量纲随阶段变化（[progress] 恒为 0..1）：mp4 下载阶段为字节；
  /// HLS 下载阶段为分片数；remuxing 阶段为 remux 输入字节（第二段 0..1 进度）；
  /// completed 后回填为最终 mp4 文件字节数（终态单位真实）。
  final int totalBytes;

  /// 已完成量，量纲同 [totalBytes]。
  final int downloadedBytes;

  final String? mp4Path;

  /// mp4 断点续传用的资源 ETag（HEAD 返回时即持久化，冷启动后仍可校验内容未变）。
  final String? etag;
  final bool saveToAlbum;
  final bool albumSaved;
  final String? albumError;
  final String? error;
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

  bool get isFinished => status == TaskStatus.completed;

  bool get isActive =>
      status == TaskStatus.running ||
      status == TaskStatus.queued ||
      status == TaskStatus.remuxing;

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
