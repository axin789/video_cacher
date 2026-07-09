import 'dart:developer' as developer;

import 'dart_transmuxer/dart_transmuxer.dart';
import 'remuxer.dart';

/// 组合两个 [Remuxer]：先跑 [primary]（纯 Dart transmuxer），
/// 遇到 [UnsupportedStreamException] 或任何异常 / `ok==false` 时，
/// 记录原因并转交 [fallback]（native FFmpeg）。
class FallbackRemuxer implements Remuxer {
  final Remuxer primary;
  final Remuxer fallback;

  static const String _logName = 'ffmpeg_remux.transmux';

  /// 记录当前活跃的实现，供 [cancel] 转发。
  final Map<String, Remuxer> _active = {};

  FallbackRemuxer({required this.primary, required this.fallback});

  @override
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles,
    required String outMp4,
    required String dir,
    void Function(int bytes)? onProgress,
  }) async {
    _active[taskId] = primary;
    try {
      final res = await primary.remux(
        taskId: taskId,
        segmentFiles: segmentFiles,
        outMp4: outMp4,
        dir: dir,
        onProgress: onProgress,
      );
      if (res.ok) return res;
      developer.log(
        'primary remux failed (${res.error}) -> fallback to native',
        name: _logName,
      );
    } on UnsupportedStreamException catch (e) {
      developer.log('unsupported stream: ${e.reason}', name: _logName);
    } catch (e) {
      developer.log('primary remux threw ($e) -> fallback to native',
          name: _logName);
    }

    _active[taskId] = fallback;
    try {
      return await fallback.remux(
        taskId: taskId,
        segmentFiles: segmentFiles,
        outMp4: outMp4,
        dir: dir,
        onProgress: onProgress,
      );
    } finally {
      _active.remove(taskId);
    }
  }

  @override
  void cancel(String taskId) {
    _active[taskId]?.cancel(taskId);
  }

  @override
  Future<void> cleanup({
    required String dir,
    required String? outMp4,
    required bool success,
  }) {
    // 两个实现的 cleanup 语义一致，用 primary 的即可。
    return primary.cleanup(dir: dir, outMp4: outMp4, success: success);
  }
}
