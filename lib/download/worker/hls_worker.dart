import 'dart:async';
import 'dart:io';
import 'dart:developer' as dev;

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/m3u8_models.dart';
import '../processor/post_processor.dart';
import '../utils/file_name.dart';
import '../utils/hls_parser_service.dart';
import 'base_worker.dart';

typedef HlsRefreshUrl = Future<String> Function(String id);

class _SegPool {
  int running = 0;
  final int max;
  final _q = <Future<void> Function()>[];

  _SegPool(this.max);

  Future<void> add(Future<void> Function() job) async {
    final c = Completer<void>();
    _q.add(() async {
      try {
        await job();
        if (!c.isCompleted) c.complete();
      } catch (e, st) {
        if (!c.isCompleted) c.completeError(e, st);
      }
    });
    _pump();
    return c.future;
  }

  void _pump() {
    while (running < max && _q.isNotEmpty) {
      final job = _q.removeAt(0);
      running++;
      job().whenComplete(() {
        running--;
        _pump();
      });
    }
  }
}

class HlsWorker extends BaseWorker<M3u8Task> {
  final Dio dio;
  @override
  final M3u8Task task;
  final int segConcurrency;

  /// Android/iOS PostProcessor，从外部注入
  final PostProcessor postProcessor;

  final void Function(M3u8Task)? onProgress;
  final void Function(M3u8Task)? onDone;
  final HlsRefreshUrl? refreshUrl;

  bool _paused = false;
  bool _canceled = false;
  late final _SegPool _pool;

  int _seqBase = 0;

  /// 下载 key 也要能 cancel
  CancelToken? _keyToken;

  Future<void>? _refreshingUrls;

  HlsWorker({
    required this.dio,
    required this.task,
    required this.postProcessor,
    this.segConcurrency = 2,
    this.onProgress,
    this.onDone,
    this.refreshUrl,
  }) {
    _pool = _SegPool(segConcurrency);
  }

  Future<bool> _isDownloadReady() async {
    // 1) local.m3u8 存在
    final m3u8File = File(p.join(task.dir, 'local.m3u8'));
    if (!await m3u8File.exists()) return false;

    // 2) segments 为空（从 store 恢复的任务），认为已下载完成（更严谨你可扫目录）
    if (task.segments.isEmpty) return true;

    // 3) segments 全 done
    return task.segments.every((s) => s.done);
  }

  @override
  Future<void> start() async {
    dev.log('[HLS] start task=${task.taskId} status=${task.status}');
    try {
      await Directory(task.dir).create(recursive: true);

      // 如果已下载完成，直接进入 postProcessing
      if (await _isDownloadReady()) {
        final m3u8Path = p.join(task.dir, 'local.m3u8');
        task.hlsLocalM3u8Path = m3u8Path;
        task.localPath = m3u8Path; // 未 remux 前，可先用 m3u8 播放（iOS 走代理）
        onProgress?.call(task);

        await _doPostProcess(m3u8Path);
        return;
      }

      // ---------- parse ----------
      final hls = HlsParserService(dio);
      final parsed = await _parseWithRefresh(hls);

      task.segments = parsed.segments;
      task.persistedTotal = parsed.segments.length;
      task.completed = task.segments.where((s) => s.done).length;
      task.key = parsed.key;
      _seqBase = parsed.mediaSequenceBase;

      onProgress?.call(task);

      // ---------- download key ----------
      if (_paused || _canceled) {
        _finishByControl();
        return;
      }

      if (task.key?.uri != null && task.key?.localName != null) {
        final keyFile = File(p.join(task.dir, task.key!.localName!));
        if (!await keyFile.exists()) {
          await _downloadKeyWithRefresh(keyFile.path);
        }
      }

      // ---------- download segments ----------
      if (_paused || _canceled) {
        _finishByControl();
        return;
      }

      final pending = task.segments.where((s) => !s.done).toList();
      final futures = <Future<void>>[];
      for (final seg in pending) {
        futures.add(_pool.add(() => _downloadRaw(seg)));
      }
      await Future.wait(futures);

      if (_paused || _canceled) {
        _finishByControl();
        return;
      }

      // 关键一致性校验：分片不完整时直接失败，避免写出坏 m3u8 并进入后处理
      if (!task.segments.every((s) => s.done)) {
        task.status = TaskStatus.failed;
        task.error = 'segment download incomplete';
        onDone?.call(task);
        return;
      }

      // ---------- write local m3u8 ----------
      final m3u8Path = await _writeLocalM3u8();
      task.hlsLocalM3u8Path = m3u8Path;
      task.localPath = m3u8Path; // remux 前先可播放
      onProgress?.call(task);

      if (_paused || _canceled) {
        _finishByControl();
        return;
      }

      // ---------- post process ----------
      await _doPostProcess(m3u8Path);
    } catch (e) {
      task.status = TaskStatus.failed;
      task.error = e.toString();
      onDone?.call(task);
    }
  }

  Future<void> _doPostProcess(String m3u8Path) async {
    task.status = TaskStatus.postProcessing;
    task.postAttempts += 1;
    onProgress?.call(task);

    final safeName = sanitizeFileName(task.name, fallback: task.taskId);
    final finalOutMp4 = p.join(task.dir, '$safeName.mp4');
    final tmpOutMp4 = p.join(task.dir, '$safeName.remux_tmp.mp4');

    try {
      final tmpFile = File(tmpOutMp4);
      if (await tmpFile.exists()) {
        try { await tmpFile.delete(); } catch (_) {}
      }

      final r = await postProcessor
          .run(
            inM3u8: m3u8Path,
            outMp4: tmpOutMp4,
            task: task,
            onBytes: (bytes) {
              task.remuxBytes = bytes;
              onProgress?.call(task);
            },
          )
          .timeout(const Duration(minutes: 20), onTimeout: () {
            return PostProcessResult(ret: -9901, outMp4: tmpOutMp4);
          });

      if (_paused || _canceled) {
        // 最小改动实现“强取消语义”：取消后即使 native 返回成功，也不产出最终 mp4
        try { if (await tmpFile.exists()) await tmpFile.delete(); } catch (_) {}
        _finishByControl();
        return;
      }

      if (r.ret == 0) {
        final produced = File(r.outMp4 ?? tmpOutMp4);
        if (!await produced.exists()) {
          task.status = TaskStatus.failed;
          task.error = 'postProcess success but output missing';
          onDone?.call(task);
          return;
        }
        final outSize = await produced.length();
        if (outSize <= 1024) {
          task.status = TaskStatus.failed;
          task.error = 'postProcess output too small: $outSize';
          onDone?.call(task);
          return;
        }

        final finalFile = File(finalOutMp4);
        if (await finalFile.exists()) {
          try { await finalFile.delete(); } catch (_) {}
        }
        await produced.rename(finalOutMp4);

        //统一产物字段
        task.mp4Path = finalOutMp4;
        task.localPath = finalOutMp4;
        task.status = TaskStatus.completed;
        task.error = null;
        onProgress?.call(task);

        // 只在成功时清理 ts/key/m3u8（保留 mp4）
        await postProcessor.cleanup(
          task: task,
          inM3u8: m3u8Path,
          outMp4: finalOutMp4,
          success: true,
        );

        onDone?.call(task);
        return;
      }

      // 失败：不清理，保留 ts 等待重试
      task.status = TaskStatus.failed;
      task.error = 'postProcess ret=${r.ret}';
      onProgress?.call(task);
      onDone?.call(task);
    } catch (e) {
      task.status = TaskStatus.failed;
      task.error = 'postProcess error: $e';
      onDone?.call(task);
    }
  }

  Future<HlsParsedResult> _parseWithRefresh(HlsParserService hls) async {
    try {
      return await hls.parseFromEntryUrl(task.url);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if ((code == 404 || code == 410) && refreshUrl != null) {
        final newUrl = await refreshUrl!(task.taskId);
        if (newUrl.trim().isNotEmpty) {
          task.url = newUrl.trim();
          return hls.parseFromEntryUrl(task.url);
        }
      }
      rethrow;
    }
  }

  Future<void> _downloadKeyWithRefresh(String keyPath) async {
    const maxRetry = 3;
    var retry = 0;
    while (true) {
      if (_paused || _canceled) return;
      try {
        _keyToken = CancelToken();
        await dio.download(task.key!.uri!, keyPath, cancelToken: _keyToken);
        return;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) return;
        if (_isExpiredStatus(e.response?.statusCode)) {
          await _refreshHlsUrlsIfNeeded();
          continue;
        }
        retry++;
        if (retry > maxRetry) rethrow;
        await Future.delayed(Duration(seconds: 1 << (retry - 1)));
      }
    }
  }

  bool _isExpiredStatus(int? code) => code == 404 || code == 410;

  bool _isNetworkDownError(DioException e) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return true;
    }
    final msg = e.error?.toString().toLowerCase() ?? '';
    return msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('network is unreachable');
  }

  Future<void> _refreshHlsUrlsIfNeeded() async {
    if (refreshUrl == null) return;
    if (_refreshingUrls != null) return _refreshingUrls!;

    final f = _refreshHlsUrls();
    _refreshingUrls = f;
    try {
      await f;
    } finally {
      if (identical(_refreshingUrls, f)) {
        _refreshingUrls = null;
      }
    }
  }

  Future<void> _refreshHlsUrls() async {
    final newUrl = await refreshUrl!(task.taskId);
    final trimmed = newUrl.trim();
    if (trimmed.isEmpty) return;

    task.url = trimmed;
    final hls = HlsParserService(dio);
    final parsed = await hls.parseFromEntryUrl(task.url);

    if (parsed.segments.length != task.segments.length) {
      throw StateError('playlist segment count changed: old=${task.segments.length}, new=${parsed.segments.length}');
    }

    for (var i = 0; i < task.segments.length; i++) {
      task.segments[i].remoteUri = parsed.segments[i].remoteUri;
      task.segments[i].duration = parsed.segments[i].duration;
    }

    task.key = parsed.key;
    _seqBase = parsed.mediaSequenceBase;
    onProgress?.call(task);
  }

  Future<void> _downloadRaw(Segment seg) async {
    if (_paused || _canceled) return;

    final file = File(p.join(task.dir, seg.localName));
    if (await file.exists()) {
      seg.done = true;
      task.completed++;
      onProgress?.call(task);
      return;
    }

    final tmp = File(p.join(task.dir, '${seg.localName}.part'));
    tmp.parent.createSync(recursive: true);

    seg.token = CancelToken();
    const maxRetry = 3;

    for (;;) {
      if (_paused || _canceled) return;
      try {
        await dio.download(seg.remoteUri, tmp.path, cancelToken: seg.token);
        await tmp.rename(file.path);
        seg.done = true;
        task.completed++;
        onProgress?.call(task);
        break;
      } catch (e) {
        if (e is DioException && e.type == DioExceptionType.cancel) return;

        // 断网/连接异常：快速失败，避免长时间卡在 running
        if (e is DioException && _isNetworkDownError(e)) {
          throw StateError('network unavailable');
        }

        if (e is DioException && _isExpiredStatus(e.response?.statusCode)) {
          await _refreshHlsUrlsIfNeeded();
          continue;
        }
        if (++seg.retry > maxRetry) {
          throw StateError('segment failed: ${seg.remoteUri}');
        }
        await Future.delayed(Duration(seconds: 1 << (seg.retry - 1))); // 1,2,4s
      }
    }
  }

  Future<String> _writeLocalM3u8() async {
    final out = StringBuffer();
    out.writeln('#EXTM3U');
    out.writeln('#EXT-X-VERSION:3');
    out.writeln('#EXT-X-MEDIA-SEQUENCE:$_seqBase');

    double maxSec = 1;
    for (final s in task.segments) {
      final sec = _toSeconds(s.duration);
      if (sec > maxSec) maxSec = sec;
    }
    out.writeln('#EXT-X-TARGETDURATION:${maxSec.ceil()}');

    final key = task.key;
    if (key?.localName != null) {
      final method = (key?.method?.trim().isNotEmpty ?? false) ? key!.method!.trim() : 'AES-128';

      String ivPart = '';
      final iv = key?.ivHex?.trim();
      if (iv != null && iv.isNotEmpty) {
        final fixedIv = (iv.startsWith('0x') || iv.startsWith('0X')) ? iv : '0x$iv';
        ivPart = ',IV=$fixedIv';
      }

      out.writeln('#EXT-X-KEY:METHOD=$method,URI="${key!.localName!}"$ivPart');
    }

    for (final s in task.segments) {
      final sec = _toSeconds(s.duration);
      out.writeln('#EXTINF:${sec.toStringAsFixed(6)},');
      out.writeln(s.localName);
    }

    out.writeln('#EXT-X-ENDLIST');

    final m3u8File = File(p.join(task.dir, 'local.m3u8'));
    await m3u8File.writeAsString(out.toString(), flush: true);
    return m3u8File.path;
  }

  double _toSeconds(int d) {
    // 微秒
    if (d >= 1_000_000) return d / 1_000_000.0;
    // 毫秒
    if (d >= 1_000) return d / 1_000.0;
    // 秒
    return d.toDouble();
  }

  @override
  void pause() {
    _paused = true;

    // cancel key
    _keyToken?.cancel('paused');
    _keyToken = null;

    // cancel segments
    for (final s in task.segments) {
      s.token?.cancel('paused');
    }

    // 尝试中断后处理(remux)
    postProcessor.cancel(task);
  }

  @override
  Future<void> cancel({bool deleteFiles = false}) async {
    _canceled = true;

    // 尝试中断后处理(remux)
    postProcessor.cancel(task);

    _keyToken?.cancel('canceled');
    _keyToken = null;

    for (final s in task.segments) {
      s.token?.cancel('canceled');
    }

    if (deleteFiles) {
      try {
        await Directory(task.dir).delete(recursive: true);
      } catch (_) {}
    }
  }

  void _finishByControl() {
    if (_canceled) {
      task.status = TaskStatus.canceled;
    } else if (_paused) {
      task.status = TaskStatus.paused;
    }
    onDone?.call(task);
  }
}