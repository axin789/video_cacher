import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../log.dart';
import '../remuxer.dart';
import 'aac_adts.dart';
import 'h264_parser.dart';
import 'mp4_builder.dart';
import 'ts_demuxer.dart';

/// 输入流不受纯 Dart transmuxer 支持（如 H.265、无 AAC 音轨、缺 SPS/PPS）。
///
/// 当前无兜底实现，抛出后任务会以该消息标记为 failed。
class UnsupportedStreamException implements Exception {
  final String reason;
  const UnsupportedStreamException(this.reason);
  @override
  String toString() => 'UnsupportedStreamException: $reason';
}

/// 纯 Dart 的 H.264 + AAC TS→MP4 转封装（remux，不转码）。
///
/// 逐分片喂入解复用器，抽取视频访问单元与音频 ADTS 帧，重写为 ISO-BMFF。
/// 时间基线 / edit list / ctts 逻辑复刻已 framemd5 验证的原型。
class DartTransmuxer implements Remuxer {
  static const String _logName = 'video_cacher.transmux';

  final Set<String> _canceled = {};

  /// 日志统一走 [VideoCacherLog.verbose] 开关（已从包入口导出，宿主可静音）。
  void _log(String msg) {
    if (VideoCacherLog.verbose) developer.log(msg, name: _logName);
  }

  @override
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles,
    required String outMp4,
    required String dir,
    void Function(int bytes)? onProgress,
  }) async {
    _canceled.remove(taskId);
    final sw = Stopwatch()..start();
    try {
      final result = await _run(taskId, segmentFiles, outMp4, onProgress, sw);
      return result;
    } on UnsupportedStreamException catch (e) {
      _log('unsupported: ${e.reason}');
      return RemuxResult(ok: false, error: e.toString());
    } catch (e, st) {
      _log('error: $e');
      if (VideoCacherLog.verbose) {
        developer.log('transmux failed',
            name: _logName, error: e, stackTrace: st);
      }
      return RemuxResult(ok: false, error: e.toString());
    }
  }

  /// 分片读取块大小：小于新生代大对象阈值，读缓冲与 PES 中转拷贝都能被
  /// 廉价的 scavenge 回收，不在老生代堆积（大块读会把整段钉进老生代）。
  static const int _feedChunkSize = 16 * 1024;

  Future<RemuxResult> _run(
    String taskId,
    List<String> segmentFiles,
    String outMp4,
    void Function(int bytes)? onProgress,
    Stopwatch sw,
  ) async {
    // ---- demux + video 转换：边喂边转 ----
    // 视频单元一完成（不会再收续包）就立刻转成 AVCC 并释放 PES 缓冲：
    // 全程只驻留一份视频数据（AVCC），而不是 PES + AVCC 两份。
    final demux = TsDemuxer();
    int totalBytes = 0;
    Uint8List? sps, pps;
    final vsamples = <VideoSample>[];
    int iCount = 0, pCount = 0, bCount = 0;

    void convertVideoUnit(PesUnit u) {
      final raw = u.data.takeBytes(); // 单块零拷贝取出并清空原缓冲
      if (u.pts == null) return;
      final nals = splitNals(raw);
      if (nals.isEmpty) return;
      bool key = false;
      // 精确分配 AVCC 缓冲一次填充（4 字节长度前缀 + NAL 体），零中间垃圾
      var total = 0;
      for (final nal in nals) {
        if (nal.isNotEmpty) total += 4 + nal.length;
      }
      final data = Uint8List(total);
      var w = 0;
      for (final nal in nals) {
        if (nal.isEmpty) continue;
        final type = nal[0] & 0x1f;
        if (type == NalType.sps) {
          sps ??= Uint8List.fromList(nal);
        } else if (type == NalType.pps) {
          pps ??= Uint8List.fromList(nal);
        }
        if (type == NalType.idr) key = true;
        data[w++] = (nal.length >> 24) & 0xff;
        data[w++] = (nal.length >> 16) & 0xff;
        data[w++] = (nal.length >> 8) & 0xff;
        data[w++] = nal.length & 0xff;
        data.setRange(w, w + nal.length, nal);
        w += nal.length;
      }
      vsamples.add(VideoSample(data, u.pts!, u.dts!, key));
      // I/P/B 统计：pts>dts 记为 B（含重排），关键帧记为 I，其余 P
      if (key) {
        iCount++;
      } else if (u.pts! > u.dts!) {
        bCount++;
      } else {
        pCount++;
      }
    }

    // 只转换「已封口」的单元：最后一个可能还会被有界 PES 的续包并回，
    // 留到出现更新单元或 finish 后再转。
    void drainVideo({required bool all}) {
      final units = demux.video?.units;
      if (units == null || units.isEmpty) return;
      final end = all ? units.length : units.length - 1;
      if (end <= 0) return;
      for (var i = 0; i < end; i++) {
        convertVideoUnit(units[i]);
      }
      units.removeRange(0, end);
    }

    for (final path in segmentFiles) {
      final raf = await File(path).open();
      try {
        while (true) {
          if (_canceled.contains(taskId)) {
            return const RemuxResult(ok: false, error: 'canceled');
          }
          final chunk = await raf.read(_feedChunkSize);
          if (chunk.isEmpty) break;
          totalBytes += chunk.length;
          demux.feed(chunk);
          // PMT 一见即校验视频编码：h265 等大任务不必读完全部分片才报错
          _failFastOnPmt(demux);
          drainVideo(all: false);
        }
      } finally {
        await raf.close();
      }
    }
    demux.finish();
    drainVideo(all: true);

    _log('input: ${segmentFiles.length} segments, $totalBytes bytes');

    final video = demux.video;
    final audio = demux.audio;
    final vType = demux.videoStreamType;
    final aType = demux.audioStreamType;

    final vCodec = vType == TsStreamType.h264
        ? 'h264'
        : vType == TsStreamType.hevc
            ? 'h265'
            : 'video(0x${(vType ?? 0).toRadixString(16)})';
    final aCodec = aType == TsStreamType.aacAdts
        ? 'aac'
        : aType == null
            ? 'none'
            : 'audio(0x${aType.toRadixString(16)})';
    _log('codecs: video=$vCodec audio=$aCodec');

    if (video == null || vType != TsStreamType.h264) {
      throw UnsupportedStreamException(
        'video codec $vCodec not supported yet (only h264)',
      );
    }
    if (audio == null || aType != TsStreamType.aacAdts) {
      throw UnsupportedStreamException(
        'audio codec $aCodec not supported yet (only AAC-ADTS)',
      );
    }

    // sps/pps 被闭包捕获不参与类型提升，判空后固定成局部非空引用
    final vSps = sps;
    final vPps = pps;
    if (vSps == null || vPps == null) {
      throw const UnsupportedStreamException('missing SPS/PPS');
    }
    if (vsamples.isEmpty) {
      throw const UnsupportedStreamException('no video frames');
    }
    _log('video: sps=${vSps.isNotEmpty} pps=${vPps.isNotEmpty} '
        'frames=${vsamples.length} I=$iCount P=$pCount B=$bCount');

    // 音频首个 PTS（供全局基线）：必须在清空 audio.units 前提取
    int firstAudioPts = vsamples.first.dts;
    for (final u in audio.units) {
      if (u.pts != null) {
        firstAudioPts = u.pts!;
        break;
      }
    }

    // ---- audio：ADTS 帧（逐单元取出即释放原缓冲）----
    final aac = parseAdts(_drainUnits(audio.units));
    audio.units.clear();
    if (aac == null) {
      throw const UnsupportedStreamException('no decodable AAC frames');
    }
    _log('audio: frames=${aac.frames.length} rate=${aac.sampleRate} '
        'ch=${aac.channels} aot=${aac.objectType}');

    final dims = parseSpsDimensions(vSps);
    _log('dimensions: ${dims.width}x${dims.height}');

    if (_canceled.contains(taskId)) {
      return const RemuxResult(ok: false, error: 'canceled');
    }

    // 原子写：先流式写 .part 再 rename，进程被杀不会在最终路径留下半截 mp4。
    final partPath = '$outMp4.part';
    final built = await buildMp4(
      vsamples: vsamples,
      sps: vSps,
      pps: vPps,
      width: dims.width,
      height: dims.height,
      aac: aac,
      firstAudioPts: firstAudioPts,
      outPath: partPath,
    );

    _log('timing: firstPts=${built.firstPts} firstDts=${built.firstDts} '
        'ts=${built.videoTimescale} elst.empty=${built.emptyEditDur} '
        'elst.mediaTime=${built.mediaStart} vDur=${built.videoTotalDur} '
        'ctts[0..]=${built.firstCtts}');
    _log('boxes: mdat=${built.mdatSize} moov=${built.moovSize}');

    await File(partPath).rename(outMp4);
    onProgress?.call(built.fileSize);

    sw.stop();
    _log('done: wrote ${built.fileSize} bytes in ${sw.elapsedMilliseconds}ms');
    return RemuxResult(ok: true, outMp4: outMp4);
  }

  /// 逐个取出 PES 单元的字节并清掉其内部缓冲，供解析方边消费边释放。
  static Iterable<Uint8List> _drainUnits(List<PesUnit> units) sync* {
    for (final u in units) {
      yield u.data.takeBytes();
    }
  }

  /// PMT 已见但视频不是 h264 时立即失败，错误里列出 PMT 全部 stream_type。
  /// PMT 出现在后续分片的流仍走原有的流尾兜底检查。
  void _failFastOnPmt(TsDemuxer demux) {
    if (!demux.pmtSeen) return;
    if (demux.videoStreamType == TsStreamType.h264) return;
    final types = demux.pmtStreamTypes.map((t) {
      final hex = '0x${t.toRadixString(16).padLeft(2, '0')}';
      if (TsStreamType.isVideo(t)) return 'video=$hex${_codecLabel(t)}';
      if (TsStreamType.isAudio(t)) return 'audio=$hex${_codecLabel(t)}';
      return 'other=$hex';
    }).join(' ');
    throw UnsupportedStreamException(
      'PMT stream types: $types — only h264+aac supported',
    );
  }

  static String _codecLabel(int t) {
    switch (t) {
      case TsStreamType.h264:
        return '(h264)';
      case TsStreamType.hevc:
        return '(hevc)';
      case TsStreamType.aacAdts:
        return '(aac)';
      default:
        return '';
    }
  }

  @override
  void cancel(String taskId) {
    _canceled.add(taskId);
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
