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
  //业务唯一ID(用作任务目录名/持久化key)
  final String taskId;

  //用于重新下载的参数
  final String movieId;
  final String lid;

  //展示用
  final String name;
  final String coverImg;

  final String url;
  final String dir;

  SourceKind kind;

  //hls专用
  List<Segment> segments;
  KeyInfo? key;

  //mp4专用
  int? contentLength; //总大小(字节)
  int downloaded; //已下载(字节)
  String? eTag;
  String? tmpPath;

  //公共
  TaskStatus status;
  int completed;
  String? error;
  int? persistedTotal;
  String? localPath;

  String? mp4Path;     // Android: 最终 mp4
  String? playUrl;     // iOS: proxy url 或 local.m3u8 path
  int remuxBytes;      // Android: remux 过程输出文件增长 bytes
  int postAttempts = 0;    // 转换尝试次数（可选）

  M3u8Task({
    required this.taskId,
    required this.movieId,
    required this.lid,
    required this.name,
    required this.coverImg,
    required this.kind,
    required this.url,
    required this.dir,

    this.status = TaskStatus.queued,
    this.completed = 0,
    this.persistedTotal,
    this.error,

    //hls
    required this.segments,
    required this.key,

    //mp4
    this.contentLength,
    this.downloaded = 0,
    this.eTag,
    this.tmpPath,
    this.localPath = '',

    this.mp4Path,
    this.playUrl,
    this.remuxBytes = 0,
    this.postAttempts = 0
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
    );
  }

  //运行时计算:当前m3u8的总分片数(已解析则为segments.length)
  int get total => segments.length;

  //UI渲染用:为解析前使用快照总数
  int get effectiveTotal {
    if (kind == SourceKind.hls) {
      return total > 0 ? total : (persistedTotal ?? 0);
    } else {
      return contentLength ?? persistedTotal ?? 0;
    }
  }

  bool get isFinished => status == TaskStatus.completed;

  bool get isActive => status == TaskStatus.running || status == TaskStatus.queued;

  bool get hasPlayable {
    if (kind == SourceKind.hls) {
      // iOS：playUrl 或 localPath 存在
      return (playUrl?.isNotEmpty ?? false) || (localPath?.isNotEmpty ?? false);
    } else {
      return (mp4Path?.isNotEmpty ?? false);
    }
  }
}
