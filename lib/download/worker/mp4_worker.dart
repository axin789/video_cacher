import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../model/m3u8_models.dart';
import '../utils/file_name.dart';
import 'base_worker.dart';

typedef Mp4RefreshUrl = Future<String> Function(String id);

class Mp4Worker extends BaseWorker<M3u8Task> {
  final Dio dio;
  @override
  final M3u8Task task;

  final void Function(M3u8Task)? onProgress;
  final void Function(M3u8Task)? onDone;
  final Mp4RefreshUrl? refreshUrl;

  CancelToken? _token;
  bool _paused = false;
  bool _canceled = false;

  Mp4Worker({
    required this.dio,
    required this.task,
    this.onProgress,
    this.onDone,
    this.refreshUrl,
  });

  @override
  Future<void> start() async {
    try {
      await Directory(task.dir).create(recursive: true);

      final safeName = sanitizeFileName(task.name.isEmpty ? task.taskId : task.name, fallback: task.taskId);
      final outPath = p.join(task.dir, '$safeName.mp4');
      final partPath = task.tmpPath ?? p.join(task.dir, '$safeName.mp4.part');
      task.tmpPath = partPath;

      // 1) HEAD 获取长度 / ETag（若 URL 失效，尝试刷新）
      try {
        final head = await dio.head(task.url, options: Options(followRedirects: true));
        task.contentLength = int.tryParse(head.headers.value(Headers.contentLengthHeader) ?? '');
        task.persistedTotal = task.contentLength ?? task.persistedTotal;
        task.eTag = head.headers.value('etag') ?? head.headers.value('eTag');
      } on DioException catch (e) {
        if (await _tryRefreshUrlOnExpired(e)) {
          final head = await dio.head(task.url, options: Options(followRedirects: true));
          task.contentLength = int.tryParse(head.headers.value(Headers.contentLengthHeader) ?? '');
          task.persistedTotal = task.contentLength ?? task.persistedTotal;
          task.eTag = head.headers.value('etag') ?? head.headers.value('eTag');
        } else {
          // 部分 CDN/源站不支持 HEAD，允许继续 GET 下载
          task.contentLength = null;
        }
      }

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

      // 4) Range 续传下载（兼容服务端忽略 Range 返回 200）
      _token = CancelToken();
      final resp = await _downloadStream(downloaded);

      // 已有 partial 且服务端不返回 206，说明无法续传：回退为从头下载，避免 append 产物损坏
      if (downloaded > 0 && resp.statusCode == 200) {
        if (await part.exists()) {
          try { await part.delete(); } catch (_) {}
        }
        downloaded = 0;
        task.downloaded = 0;
        task.completed = 0;
        _emit();
      } else if (downloaded > 0 && resp.statusCode != 206) {
        throw StateError('range resume not supported: status=${resp.statusCode}');
      }

      final sink = part.openWrite(mode: downloaded > 0 ? FileMode.append : FileMode.write);
      try {
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
      final shouldComplete =
          (task.contentLength != null && downloaded >= task.contentLength!) ||
          (task.contentLength == null && downloaded > 0);

      if (shouldComplete) {
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

  Future<Response<ResponseBody>> _downloadStream(int downloaded) async {
    try {
      return await dio.get<ResponseBody>(
        task.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: (downloaded > 0) ? {'Range': 'bytes=$downloaded-'} : null,
          followRedirects: true,
        ),
        cancelToken: _token,
      );
    } on DioException catch (e) {
      if (await _tryRefreshUrlOnExpired(e)) {
        return dio.get<ResponseBody>(
          task.url,
          options: Options(
            responseType: ResponseType.stream,
            headers: (downloaded > 0) ? {'Range': 'bytes=$downloaded-'} : null,
            followRedirects: true,
          ),
          cancelToken: _token,
        );
      }
      rethrow;
    }
  }

  Future<bool> _tryRefreshUrlOnExpired(DioException e) async {
    final code = e.response?.statusCode;
    if ((code == 404 || code == 410) && refreshUrl != null) {
      final newUrl = await refreshUrl!(task.taskId);
      if (newUrl.trim().isNotEmpty) {
        task.url = newUrl.trim();
        return true;
      }
    }
    return false;
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