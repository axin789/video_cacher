import 'package:dio/dio.dart';

enum TaskStatus { queued, running, paused, completed, failed, canceled, postProcessing }

enum SourceKind { hls, mp4 }

class Segment {
  final int index;
  final String remoteUri;
  final String localName;
  bool done;
  int retry;
  CancelToken? token;
  int duration;

  Segment({required this.index, required this.remoteUri, required this.localName, this.done = false, this.retry = 0, this.duration = 0});
}

class KeyInfo {
  String? method;
  String? uri;
  String? localName;
  String? ivHex;
}

class M3u8Task {
  // 业务唯一ID(用作任务目录名/持久化key)
  final String taskId;

  // 用于重新下载的参数
  final String movieId;
  final String lid;

  // 展示用
  final String name;
  final String coverImg;

  final String url;
  final String dir;

  SourceKind kind;

  // ============ HLS 专用 ============
  List<Segment> segments;
  KeyInfo? key;

  /// 下载完成后写出来的本地 m3u8 绝对路径（一般是 local.m3u8）
  String? hlsLocalM3u8Path;

  // ============ MP4 / 通用产物 ============
  /// App 内播放的入口（最终建议这里：HLS 成功 remux 后也写成 mp4Path）
  String? localPath;

  /// HLS remux 成功后的 mp4 绝对路径（Android remux / iOS ffmpeg remux）
  String? mp4Path;

  /// 是否已经保存过系统相册（防重复）
  bool albumSaved;
  /// 是否自动保存到系统相册（可由 UI 创建任务时传入）
  bool saveToAlbum;


  /// 保存相册失败原因（不会影响任务 completed）
  String? albumError;

  // ============ MP4 下载专用 ============
  int? contentLength; //总大小(字节)
  int downloaded;     //已下载(字节)
  String? eTag;
  String? tmpPath;

  // ============ 公共 ============
  TaskStatus status;
  int completed;          // HLS: 已完成分片数；MP4: 可用于“已下载 bytes”
  String? error;
  int? persistedTotal;

  // ============ 进度/重试（可选） ============
  /// remux 阶段的“进度字节”
  int remuxBytes;

  /// postProcess 重试次数
  int postAttempts;

  M3u8Task({
    required this.taskId,
    required this.movieId,
    required this.lid,
    required this.name,
    required this.coverImg,
    required this.kind,
    required this.url,
    required this.dir,

    // 公共
    this.status = TaskStatus.queued,
    this.completed = 0,
    this.persistedTotal,
    this.error,

    // hls
    required this.segments,
    required this.key,
    this.hlsLocalM3u8Path,

    // mp4
    this.contentLength,
    this.downloaded = 0,
    this.eTag,
    this.tmpPath,

    // output
    this.localPath,
    this.mp4Path,

    // album
    this.albumSaved = false,
    this.saveToAlbum = true,
    this.albumError,

    // extras
    this.remuxBytes = 0,
    this.postAttempts = 0,
  });

  factory M3u8Task.fromMeta({
    required String taskId,
    required String movieId,
    required SourceKind kind,
    required String lid,
    required String name,
    required String coverImg,
    required String url,
    required String dir,
    bool saveToAlbum = true,
  }) {
    return M3u8Task(
      taskId: taskId,
      movieId: movieId,
      lid: lid,
      kind: kind,
      name: name,
      coverImg: coverImg,
      url: url,
      dir: dir,
      segments: [],
      key: null,
      status: TaskStatus.queued,
      saveToAlbum: saveToAlbum,
      albumSaved: false,
    );
  }

  // 运行时计算:当前m3u8的总分片数(已解析则为segments.length)
  int get total => segments.length;

  // UI 渲染用：解析前使用快照总数
  int get effectiveTotal {
    if (kind == SourceKind.hls) {
      return total > 0 ? total : (persistedTotal ?? 0);
    } else {
      return contentLength ?? persistedTotal ?? 0;
    }
  }

  bool get isFinished => status == TaskStatus.completed;
  bool get isActive => status == TaskStatus.running || status == TaskStatus.queued;

  /// 是否已经有可播放产物（本地 mp4 或本地 m3u8）
  bool get hasPlayableLocal =>
      (localPath != null && localPath!.isNotEmpty) ||
          (mp4Path != null && mp4Path!.isNotEmpty) ||
          (hlsLocalM3u8Path != null && hlsLocalM3u8Path!.isNotEmpty);
}
