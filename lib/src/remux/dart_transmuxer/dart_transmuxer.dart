import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

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
  /// 日志开关，默认开启，方便联调时观察；可后续静音。
  static bool verbose = true;

  static const String _logName = 'video_cacher.transmux';

  final Set<String> _canceled = {};

  void _log(String msg) {
    if (verbose) developer.log(msg, name: _logName);
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
      developer.log('transmux failed', name: _logName, error: e, stackTrace: st);
      return RemuxResult(ok: false, error: e.toString());
    }
  }

  Future<RemuxResult> _run(
    String taskId,
    List<String> segmentFiles,
    String outMp4,
    void Function(int bytes)? onProgress,
    Stopwatch sw,
  ) async {
    // ---- demux：逐分片喂入 ----
    final demux = TsDemuxer();
    int totalBytes = 0;
    for (final path in segmentFiles) {
      if (_canceled.contains(taskId)) {
        return const RemuxResult(ok: false, error: 'canceled');
      }
      final bytes = await File(path).readAsBytes();
      totalBytes += bytes.length;
      demux.feed(bytes);
    }
    demux.finish();

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

    // ---- video：一个 PES = 一个 AU ----
    Uint8List? sps, pps;
    final vsamples = <VideoSample>[];
    int iCount = 0, pCount = 0, bCount = 0;
    for (final u in video.units) {
      if (_canceled.contains(taskId)) {
        return const RemuxResult(ok: false, error: 'canceled');
      }
      if (u.pts == null) continue;
      final nals = splitNals(u.data.toBytes());
      if (nals.isEmpty) continue;
      bool key = false;
      final out = BytesBuilder(copy: false);
      for (final nal in nals) {
        if (nal.isEmpty) continue;
        final type = nal[0] & 0x1f;
        if (type == NalType.sps) {
          sps ??= Uint8List.fromList(nal);
        } else if (type == NalType.pps) {
          pps ??= Uint8List.fromList(nal);
        }
        if (type == NalType.idr) key = true;
        out.add([
          (nal.length >> 24) & 0xff,
          (nal.length >> 16) & 0xff,
          (nal.length >> 8) & 0xff,
          nal.length & 0xff,
        ]);
        out.add(nal);
      }
      final sample = VideoSample(out.toBytes(), u.pts!, u.dts!, key);
      vsamples.add(sample);
      // I/P/B 统计：pts>dts 记为 B（含重排），关键帧记为 I，其余 P
      if (key) {
        iCount++;
      } else if (u.pts! > u.dts!) {
        bCount++;
      } else {
        pCount++;
      }
    }

    if (sps == null || pps == null) {
      throw const UnsupportedStreamException('missing SPS/PPS');
    }
    if (vsamples.isEmpty) {
      throw const UnsupportedStreamException('no video frames');
    }
    _log('video: sps=${sps.isNotEmpty} pps=${pps.isNotEmpty} '
        'frames=${vsamples.length} I=$iCount P=$pCount B=$bCount');

    // ---- audio：ADTS 帧 ----
    final aac = parseAdts(audio.units.map((u) => u.data.toBytes()));
    if (aac == null) {
      throw const UnsupportedStreamException('no decodable AAC frames');
    }
    _log('audio: frames=${aac.frames.length} rate=${aac.sampleRate} '
        'ch=${aac.channels} aot=${aac.objectType}');

    final dims = parseSpsDimensions(sps);
    _log('dimensions: ${dims.width}x${dims.height}');

    // 音频首个 PTS（供全局基线）
    int firstAudioPts = vsamples.first.dts;
    for (final u in audio.units) {
      if (u.pts != null) {
        firstAudioPts = u.pts!;
        break;
      }
    }

    if (_canceled.contains(taskId)) {
      return const RemuxResult(ok: false, error: 'canceled');
    }

    final built = buildMp4(
      vsamples: vsamples,
      sps: sps,
      pps: pps,
      width: dims.width,
      height: dims.height,
      aac: aac,
      firstAudioPts: firstAudioPts,
    );

    _log('timing: firstPts=${built.firstPts} firstDts=${built.firstDts} '
        'ts=${built.videoTimescale} elst.empty=${built.emptyEditDur} '
        'elst.mediaTime=${built.mediaStart} vDur=${built.videoTotalDur} '
        'ctts[0..]=${built.firstCtts}');
    _log('boxes: mdat=${built.mdatSize} moov=${built.moovSize}');

    // 原子写：先写 .part 再 rename，进程被杀不会在最终路径留下半截 mp4。
    final partPath = '$outMp4.part';
    await File(partPath).writeAsBytes(built.bytes);
    await File(partPath).rename(outMp4);
    onProgress?.call(built.bytes.length);

    sw.stop();
    _log('done: wrote ${built.bytes.length} bytes in ${sw.elapsedMilliseconds}ms');
    return RemuxResult(ok: true, outMp4: outMp4);
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
