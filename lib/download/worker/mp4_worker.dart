import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/m3u8_models.dart';
import 'base_worker.dart';

class Mp4Worker extends BaseWorker<M3u8Task> {
  final Dio dio;
  @override
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

      final safeName = task.name.isEmpty ? task.taskId : task.name;
      final outPath = p.join(task.dir, '$safeName.mp4');
      final partPath = task.tmpPath ?? p.join(task.dir, '$safeName.mp4.part');
      task.tmpPath = partPath;

      // 1) HEAD 获取长度 / ETag
      final head = await dio.head(task.url, options: Options(followRedirects: true));
      task.contentLength = int.tryParse(head.headers.value(Headers.contentLengthHeader) ?? '');
      task.persistedTotal = task.contentLength ?? task.persistedTotal;
      task.eTag = head.headers.value('etag') ?? head.headers.value('eTag');

      // 2) 读取已下载大小（断点）
      final part = File(partPath);
      int downloaded = await part.exists() ? await part.length() : 0;
      task.downloaded = downloaded;

      //  用 completed 统一承载“进度值”
      task.completed = downloaded;
      _emit();

      // 3) 已完成直接收尾
      if (task.contentLength != null && downloaded >= task.contentLength!) {
        final dst = File(outPath);
        if (!await dst.exists()) {
          await part.rename(outPath);
        } else {
          // 如果 out 已有，part 也可能存在，清理一下
          if (await part.exists()) {
            try { await part.delete(); } catch (_) {}
          }
        }

        // 成果字段统一
        task.mp4Path = outPath;
        task.localPath = outPath;
        task.status = TaskStatus.completed;
        task.error = null;

        _emitDone();
        return;
      }

      // 4) Range 续传下载
      _token = CancelToken();
      final sink = part.openWrite(mode: FileMode.append);
      try {
        final resp = await dio.get<ResponseBody>(
          task.url,
          options: Options(
            responseType: ResponseType.stream,
            headers: (downloaded > 0) ? {'Range': 'bytes=$downloaded-'} : null,
            followRedirects: true,
          ),
          cancelToken: _token,
        );

        final stream = resp.data!.stream;
        await for (final data in stream) {
          if (_paused || _canceled) break;
          sink.add(data);

          downloaded += data.length;
          task.downloaded = downloaded;
          task.completed = downloaded; // 统一：bytes 进度
          _emit();
        }
      } finally {
        await sink.close();
      }

      if (_canceled) {
        task.status = TaskStatus.canceled;
        _emitDone();
        return;
      }
      if (_paused) {
        task.status = TaskStatus.paused;
        _emitDone();
        return;
      }

      // 5) 完成：改名
      if (task.contentLength != null && downloaded >= task.contentLength!) {
        final out = File(outPath);
        if (await out.exists()) {
          // 有可能之前就存在，先删掉再覆盖
          try { await out.delete(); } catch (_) {}
        }
        await File(partPath).rename(outPath);

        task.mp4Path = outPath;
        task.localPath = outPath;
        task.status = TaskStatus.completed;
        task.error = null;
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
      try {
        await Directory(task.dir).delete(recursive: true);
      } catch (_) {}
    }
  }

  void _emit() => onProgress?.call(task);
  void _emitDone() => onDone?.call(task);
}