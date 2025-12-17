import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:ffmpeg_remux/download/worker/base_worker.dart';
import 'package:flutter/cupertino.dart';
import 'package:path/path.dart' as p;

import '../model/m3u8_models.dart';
import '../processor/post_processor.dart';
import '../utils/hls_parser_service.dart';
import '../utils/save_video_to_album.dart';


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
      } finally {
        c.complete();
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
  final M3u8Task task;
  final int segConcurrency;

  ///  Android/iOS PostProcessor，从外部注入
  final PostProcessor postProcessor;

  final void Function(M3u8Task)? onProgress;
  final void Function(M3u8Task)? onDone;

  bool _paused = false;
  bool _canceled = false;
  late final _SegPool _pool;

  int _seqBase = 0;

  //  下载 key 也要能 cancel
  CancelToken? _keyToken;

  HlsWorker({
    required this.dio,
    required this.task,
    required this.postProcessor,
    this.segConcurrency = 2,
    this.onProgress,
    this.onDone,
  }) {
    _pool = _SegPool(segConcurrency);
  }

  Future<bool> _isDownloadReady() async {
    // 1) local.m3u8 存在
    final m3u8File = File(p.join(task.dir, 'local.m3u8'));
    if (!await m3u8File.exists()) return false;

    // 2) 如果 segments 为空（从 store 恢复的任务），至少要认为已下载完成
    //   更严谨：扫描目录 seg_*.ts 数量 >= persistedTotal
    if (task.segments.isEmpty) return true;

    // 3) segments 全 done
    return task.segments.every((s) => s.done);
  }

  @override
  Future<void> start() async {
    print('[HLS] start task=${task.taskId} status=${task.status}');
    try {
      // ---------- prepare ----------
      await Directory(task.dir).create(recursive: true);

      // 如果已下载完成，直接进入 postProcessing
      if (await _isDownloadReady()) {
        final m3u8Path = p.join(task.dir, 'local.m3u8');
        task.localPath = m3u8Path;
        await _doPostProcess(m3u8Path);
        return;
      }
      final hls = HlsParserService(dio);
      final parsed = await hls.parseFromEntryUrl(task.url);

      task.segments = parsed.segments;
      task.persistedTotal = parsed.segments.length;
      task.completed = task.segments.where((s) => s.done).length;
      task.key = parsed.key;
      _seqBase = parsed.mediaSequenceBase;

      onProgress?.call(task);

      // ---------- download key (no decrypt) ----------
      if (_paused || _canceled) {
        _finishByControl();
        return;
      }

      if (task.key?.uri != null && task.key?.localName != null) {
        final keyFile = File(p.join(task.dir, task.key!.localName!));
        if (!await keyFile.exists()) {
          _keyToken = CancelToken();
          await dio.download(
            task.key!.uri!,
            keyFile.path,
            cancelToken: _keyToken,
          );
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

      // ---------- write local m3u8 ----------
      final m3u8Path = await _writeLocalM3u8();
      task.localPath = m3u8Path;

      if (_paused || _canceled) {
        _finishByControl();
        return;
      }

      // =========================
      // === post processing（Android remux / iOS proxy）
      // =========================
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

    final outMp4 = p.join(task.dir, '${task.name}.mp4'); // 你要的 mp4 名

    final r = await postProcessor.run(
      inM3u8: m3u8Path,
      outMp4: outMp4,
      task: task,
      onBytes: (bytes) {
        task.remuxBytes = bytes;
        onProgress?.call(task);
      },
    );

    if (r.ret == 0) {
      task.mp4Path = r.outMp4 ?? outMp4;
      task.status = TaskStatus.completed;
      task.error = null;
      onProgress?.call(task);

      //  只在成功时清理 ts/key/m3u8
      await postProcessor.cleanup(
        task: task,
        inM3u8: m3u8Path,
        outMp4: task.mp4Path!,
        success: true,
      );
      final ok = await AlbumSaver.saveVideo(task.mp4Path!, title: task.name);
      if (ok) {
        debugPrint("保存相册成功");
      } else {
        debugPrint("保存相册失败");
      }
      onDone?.call(task);
      return;
    }

    //失败：不清理，保留 ts 等待重试
    task.status = TaskStatus.failed;
    task.error = 'postProcess ret=${r.ret}';
    onProgress?.call(task);
    onDone?.call(task);
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
        if (++seg.retry > maxRetry) break;
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
    // 1) 微秒（最常见：mpegts / ffmpeg）
    if (d >= 1_000_000) {
      return d / 1_000_000.0;
    }

    // 2) 毫秒（部分后端 / 播放器会给）
    if (d >= 1_000) {
      return d / 1_000.0;
    }

    // 3) 已经是秒（兜底）
    return d.toDouble();
  }


  @override
  void pause() {
    _paused = true;

    // cancel key download
    _keyToken?.cancel('paused');
    _keyToken = null;

    // cancel ts downloads
    for (final s in task.segments) {
      s.token?.cancel('paused');
    }

    // ✅ 如果后处理中也支持取消，调用一下（你 PostProcessor 里可以实现 cancel）
    postProcessor.cancel.call(task);
  }

  @override
  Future<void> cancel({bool deleteFiles = false}) async {
    _canceled = true;

    _keyToken?.cancel('canceled');
    _keyToken = null;

    for (final s in task.segments) {
      s.token?.cancel('canceled');
    }

    // ✅ 通知后处理取消（比如 Android remux cancel）
    postProcessor.cancel.call(task);

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

  String _safeFileName(String s) {
    // Android/各文件系统都更稳：去掉不合法字符
    final cleaned = s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return cleaned.isEmpty ? task.taskId : cleaned;
  }
}