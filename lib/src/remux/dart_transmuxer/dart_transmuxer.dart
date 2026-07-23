import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../../log.dart';
import '../remuxer.dart';
import 'transmux_worker.dart';

/// 输入流不受纯 Dart transmuxer 支持（如 H.265、无 AAC 音轨、缺 SPS/PPS）。
///
/// 当前无兜底实现，抛出后任务会以该消息标记为 failed。
class UnsupportedStreamException implements Exception {
  final String reason;
  const UnsupportedStreamException(this.reason);
  @override
  String toString() => 'UnsupportedStreamException: $reason';
}

/// 一次 remux 的主侧状态：worker isolate + 消息端口 + 结果 completer。
class _ActiveWorker {
  final ReceivePort port; // worker 消息协议
  final ReceivePort exitPort; // worker 退出通知
  final Completer<RemuxResult> completer = Completer<RemuxResult>();
  final String outMp4;
  Isolate? isolate;
  bool canceled = false;

  _ActiveWorker(this.port, this.exitPort, this.outMp4);
}

/// 纯 Dart 的 H.264 + AAC TS→MP4 转封装（remux，不转码）。
///
/// CPU 密集的流水线整体跑在独立 isolate（见 [transmuxWorker]），主 isolate 只做
/// 消息编排：进度转发、结果映射、取消（`Isolate.kill` 强停 + 清理 `.part`）。
class DartTransmuxer implements Remuxer {
  static const String _logName = 'video_cacher.transmux';

  /// 协作取消标记：覆盖 spawn 完成前的窗口；worker 起来后取消靠 kill。
  final Set<String> _canceled = {};

  final Map<String, _ActiveWorker> _workers = {};

  /// 日志统一走 [VideoCacherLog.verbose] 开关（已从包入口导出，宿主可静音）。
  /// worker isolate 内的日志由传入的 verbose 副本控制。
  void _log(String msg) {
    if (VideoCacherLog.verbose) developer.log(msg, name: _logName);
  }

  @override
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles,
    required String outMp4,
    required String dir,
    TransmuxCrypto? crypto,
    void Function(int bytes)? onProgress,
  }) async {
    _canceled.remove(taskId);
    final sw = Stopwatch()..start();
    final w = _ActiveWorker(ReceivePort(), ReceivePort(), outMp4);
    _workers[taskId] = w;

    w.port.listen((dynamic msg) {
      final m = msg as Map<dynamic, dynamic>;
      if (m.containsKey('progress')) {
        onProgress?.call(m['progress'] as int);
      } else if (m.containsKey('done')) {
        _complete(w, RemuxResult(ok: true, outMp4: outMp4));
      } else if (m.containsKey('error')) {
        final err = m['error'] as String;
        _log(m['unsupported'] == true ? 'unsupported: $err' : 'error: $err');
        _complete(w, RemuxResult(ok: false, error: err));
      }
    });
    // worker 退出：取消路径在这里做终局清理（删 .part、落取消结果）。
    // 正常完成时 done/error 消息先于退出通知，这里自然空转。
    w.exitPort.listen((dynamic _) {
      if (w.canceled) {
        _deletePart(w.outMp4);
        _complete(w, const RemuxResult(ok: false, error: 'canceled'));
      } else {
        _complete(
            w, const RemuxResult(ok: false, error: 'transmux worker exited'));
      }
    });

    try {
      w.isolate = await Isolate.spawn(
        transmuxWorker,
        TransmuxRequest(
            w.port.sendPort, segmentFiles, outMp4, VideoCacherLog.verbose,
            crypto: crypto),
        onExit: w.exitPort.sendPort,
        debugName: 'video_cacher.transmux.$taskId',
      );
      // spawn 期间被协作取消：立刻杀掉刚起的 worker，走取消收尾。
      if (_canceled.contains(taskId)) _kill(w);
    } catch (e) {
      _log('spawn failed: $e');
      _complete(w, RemuxResult(ok: false, error: e.toString()));
    }

    try {
      final res = await w.completer.future;
      sw.stop();
      if (res.ok) _log('done in ${sw.elapsedMilliseconds}ms');
      return res;
    } finally {
      w.port.close();
      w.exitPort.close();
      _workers.remove(taskId);
    }
  }

  void _complete(_ActiveWorker w, RemuxResult result) {
    if (!w.completer.isCompleted) w.completer.complete(result);
  }

  /// 强停 worker：kill 后由 exitPort 回调删 `.part` 并落取消结果。
  void _kill(_ActiveWorker w) {
    w.canceled = true;
    final iso = w.isolate;
    if (iso != null) {
      iso.kill(priority: Isolate.immediate);
    } else {
      // worker 还没 spawn 完（或 spawn 失败）：直接按取消收尾。
      _deletePart(w.outMp4);
      _complete(w, const RemuxResult(ok: false, error: 'canceled'));
    }
  }

  void _deletePart(String outMp4) {
    // kill 强停时 worker 自己的清理代码不会运行：两遍式转封装的 ES 临时文件
    // （.v.es/.a.es）也要在主侧一并删掉。
    for (final path in ['$outMp4.part', '$outMp4.v.es', '$outMp4.a.es']) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        // 清理失败不影响取消语义。
      }
    }
  }

  @override
  void cancel(String taskId) {
    _canceled.add(taskId);
    final w = _workers[taskId];
    if (w != null && !w.canceled) _kill(w);
  }

  @override
  Future<void> cleanup({
    required String dir,
    required String? outMp4,
    required bool success,
  }) async {
    if (!success) return;
    final directory = Directory(dir);
    if (!directory.existsSync()) return;
    final keep = outMp4 == null ? null : p.normalize(outMp4);
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      if (keep != null && p.normalize(entity.path) == keep) continue;
      try {
        await entity.delete();
      } catch (_) {
        // 尽力清理，忽略单个文件删除失败
      }
    }
  }
}
