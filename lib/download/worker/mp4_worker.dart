import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import '../model/m3u8_models.dart';
import 'base_worker.dart';

class Mp4Worker extends BaseWorker<M3u8Task>{
  final Dio dio;
  final M3u8Task task;
  final void Function(M3u8Task)? onProgress;
  final void Function(M3u8Task)? onDone;
  CancelToken? _token;
  bool _paused = false;
  bool _canceled = false;

  Mp4Worker({
    required this.dio,
    required this.task,
    this.onProgress,
    this.onDone,
  });

  @override
  Future<void> start() async {
    try {
      await Directory(task.dir).create(recursive: true);
      final outPath = p.join(task.dir, 'output.mp4');
      final partPath = task.tmpPath ?? p.join(task.dir, 'output.mp4.part');

      // 1) HEAD 获取长度 / ETag / Accept-Ranges
      final head = await dio.head(task.url, options: Options(followRedirects: true));
      task.contentLength = int.tryParse(head.headers.value(Headers.contentLengthHeader) ?? '');
      task.persistedTotal = task.contentLength ?? task.persistedTotal;
      task.eTag = head.headers.value('eTag');

      // 2) 读取已下载大小（断点）
      final part = File(partPath);
      int downloaded = await part.exists() ? await part.length() : 0;
      task.downloaded = downloaded;
      _emit();

      // 3) 如果已完成且目标文件存在则直接完成
      if ((task.contentLength != null) && downloaded >= task.contentLength!) {
        // 已全量，直接 rename/拷贝
        final dst = File(outPath);
        if (!await dst.exists()) {
          await part.rename(outPath);
        }
        task.status = TaskStatus.completed;
        _emitDone();
        return;
      }

      // 4) 持续下载（Range 续传）
      _token = CancelToken();
      final sink = part.openWrite(mode: FileMode.append);
      try {
        final resp = await dio.get<ResponseBody>(
          task.url,
          options: Options(
            responseType: ResponseType.stream,
            headers: (downloaded > 0)
                ? {'Range': 'bytes=$downloaded-'}
                : null,
          ),
          cancelToken: _token,
        );

        final total = task.contentLength ?? 0;
        final stream = resp.data!.stream;
        await for (final data in stream) {
          if (_paused || _canceled) break;
          sink.add(data);
          downloaded += data.length;
          task.downloaded = downloaded;
          // 用统一的 completed 来表示 0~total 的进度（给 UI 一致性）
          task.completed = total > 0 ? downloaded : task.completed;
          _emit();
        }
      } finally {
        await sink.close();
      }

      if (_canceled) { task.status = TaskStatus.canceled; _emitDone(); return; }
      if (_paused)   { task.status = TaskStatus.paused;   _emitDone(); return; }

      // 5) 完成：改名为 output.mp4
      if (task.contentLength != null && downloaded >= task.contentLength!) {
        await File(partPath).rename(outPath);
        task.status = TaskStatus.completed;
      } else {
        task.status = TaskStatus.failed;
        task.error = 'download interrupted';
      }
      _emitDone();
    } catch (e) {
      task.status = TaskStatus.failed;
      task.error = e.toString();
      _emitDone();
    }
  }

  @override
  void pause() {
    _paused = true;
    _token?.cancel('paused');
  }

  @override
  Future<void> cancel({bool deleteFiles = false}) async {
    _canceled = true;
    _token?.cancel('canceled');
    if (deleteFiles) {
      try { await Directory(task.dir).delete(recursive: true); } catch (_) {}
    }
  }

  void _emit() => onProgress?.call(task);
  void _emitDone() => onDone?.call(task);
}
