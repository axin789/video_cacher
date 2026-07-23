import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../download/hls/aes_decryptor.dart';
import '../../log.dart';
import '../remuxer.dart' show TransmuxCrypto;
import 'aac_adts.dart';
import 'dart_transmuxer.dart' show UnsupportedStreamException;
import 'h264_parser.dart';
import 'mp4_builder.dart';
import 'ts_demuxer.dart';

const String _logName = 'video_cacher.transmux';

void _log(String msg) {
  if (VideoCacherLog.verbose) developer.log(msg, name: _logName);
}

/// 传给 remux worker isolate 的启动参数。
///
/// 静态变量不跨 isolate（worker 里读到的是自己的副本），verbose 必须显式带入。
/// [crypto] 的字段（Uint8List/Map）均可随 spawn 消息发送。
class TransmuxRequest {
  final SendPort reply;
  final List<String> segmentFiles;
  final String outMp4;
  final bool verbose;
  final TransmuxCrypto? crypto;

  const TransmuxRequest(
      this.reply, this.segmentFiles, this.outMp4, this.verbose,
      {this.crypto});
}

/// remux worker isolate 入口：跑完整条转封装流水线并经 [TransmuxRequest.reply]
/// 回报消息。协议（Map 单键）：
///  - `{'progress': 已喂入累计输入字节}`——每喂完一个分片发一次；
///  - `{'done': 产物字节数}`——成功（.part 已 rename 为 outMp4）；
///  - `{'error': 描述, 'unsupported': bool}`——失败。
///
/// 全部异常在此捕获成 error 消息，不向 isolate 顶层泄漏；强制取消由主侧
/// `Isolate.kill` 完成，本函数无协作取消点。
Future<void> transmuxWorker(TransmuxRequest req) async {
  VideoCacherLog.verbose = req.verbose; // 本 isolate 自己的静态副本
  try {
    final size = await _pipeline(req);
    req.reply.send({'done': size});
  } on UnsupportedStreamException catch (e) {
    _log('unsupported: ${e.reason}');
    req.reply.send({'error': e.toString(), 'unsupported': true});
  } catch (e, st) {
    _log('error: $e');
    if (VideoCacherLog.verbose) {
      developer.log('transmux failed',
          name: _logName, error: e, stackTrace: st);
    }
    req.reply.send({'error': e.toString(), 'unsupported': false});
  }
}

/// 分片读取块大小：小于新生代大对象阈值，读缓冲与 PES 中转拷贝都能被
/// 廉价的 scavenge 回收，不在老生代堆积（大块读会把整段钉进老生代）。
const int _feedChunkSize = 16 * 1024;

/// 分片准备前瞻数：喂第 i 片时，第 i+1..i+_prepareAhead 片的读盘/解密已在路上。
const int _prepareAhead = 2;

/// 准备一个分片：明文片整片读入（不 spawn 子 isolate——无加密输入时流水线
/// 只是按片读盘，无额外开销）；加密片的「读 + 解密」整体放子 isolate。
/// diskBytes 为磁盘文件字节数——进度按它累计，与引擎按文件长度算的
/// totalBytes 对齐（密文含 PKCS7 填充，比明文长）。
Future<({Uint8List plain, int diskBytes})> _prepareSegment(
    String path, TransmuxCrypto? crypto) async {
  final iv = crypto?.ivByPath[path];
  if (iv == null) {
    final bytes = await File(path).readAsBytes();
    return (plain: bytes, diskBytes: bytes.length);
  }
  final diskBytes = await File(path).length();
  return (
    plain: await _readAndDecryptInIsolate(path, crypto!.key, iv),
    diskBytes: diskBytes,
  );
}

/// 子 isolate 内完成加密片的「读盘 + 整片解密」（解密后置：PKCS7 去填充需要
/// 完整密文尾块；AES 是纯 CPU，off-thread 才能与 demux 并行）。读盘也放在子
/// isolate：spawn 消息只带 path/key/iv 三个小参数，几十 MB 级密文不做跨
/// isolate 深拷，明文结果经 Isolate.exit 零拷贝移回。
/// 独立的同步小函数：闭包只捕获三个参数，避免外层 async 函数上下文把不可
/// 发送对象（RandomAccessFile 等）拖进 spawn 消息。
Future<Uint8List> _readAndDecryptInIsolate(
        String path, Uint8List key, Uint8List iv) =>
    Isolate.run(() async {
      final cipher = await File(path).readAsBytes();
      return AesDecryptor.decryptCbc(cipher, key, iv);
    });

/// ES 临时文件的攒批写入器：小块（音频帧几百字节）先入缓冲，满了才落盘，
/// 避免 GB 级输入产生几十万次 write syscall。
class _EsWriter {
  final RandomAccessFile _raf;
  final Uint8List _buf = Uint8List(256 * 1024);
  int _len = 0;

  /// 已写入总字节数（即下一块数据的文件内偏移）。
  int length = 0;

  _EsWriter(this._raf);

  Future<void> add(Uint8List data) async {
    length += data.length;
    if (data.length >= _buf.length) {
      // 大块直写：先清缓冲保持顺序
      if (_len > 0) {
        await _raf.writeFrom(_buf, 0, _len);
        _len = 0;
      }
      await _raf.writeFrom(data);
      return;
    }
    if (_len + data.length > _buf.length) {
      await _raf.writeFrom(_buf, 0, _len);
      _len = 0;
    }
    _buf.setRange(_len, _len + data.length, data);
    _len += data.length;
  }

  Future<void> close() async {
    if (_len > 0) await _raf.writeFrom(_buf, 0, _len);
    await _raf.close();
  }
}

Future<int> _pipeline(TransmuxRequest req) async {
  final sw = Stopwatch()..start();
  final segmentFiles = req.segmentFiles;
  final outMp4 = req.outMp4;

  // ---- 两遍全流式：内存峰值与视频大小解耦 ----
  // 第 1 遍：demux 边喂边把已封口单元转出（视频 AU→AVCC、音频 PES→裸 AAC 帧）
  // 追加到 `<outMp4>.v.es` / `<outMp4>.a.es` 两个 ES 临时文件；内存只留
  // 每样本的 int 元数据表（偏移/大小/时间戳）。第 2 遍：按表算好全部 box，
  // 从 ES 文件区间拷贝出 mdat（见 buildMp4）。峰值 ≈ (1 + _prepareAhead)
  // 个分片 + 表（见下方分片准备流水线注释）。
  final demux = TsDemuxer();
  int totalBytes = 0;
  Uint8List? sps, pps;
  final vtable = <VideoSample>[];
  int iCount = 0, pCount = 0, bCount = 0;
  final adts = AdtsStream();
  int? firstAudioPts;

  final vEsPath = '$outMp4.v.es';
  final aEsPath = '$outMp4.a.es';

  try {
    final vEs = _EsWriter(await File(vEsPath).open(mode: FileMode.write));
    final aEs = _EsWriter(await File(aEsPath).open(mode: FileMode.write));
    try {
      Future<void> convertVideoUnit(PesUnit u) async {
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
        vtable.add(VideoSample(vEs.length, total, u.pts!, u.dts!, key));
        await vEs.add(data);
        // I/P/B 统计：pts>dts 记为 B（含重排），关键帧记为 I，其余 P
        if (key) {
          iCount++;
        } else if (u.pts! > u.dts!) {
          bCount++;
        } else {
          pCount++;
        }
      }

      // 取走已封口且不会再收续包的单元即转即写（保留最近一个，见 takeFinalized）。
      Future<void> drain({required bool all}) async {
        final video = demux.video;
        if (video != null) {
          for (final u in video.takeFinalized(all: all)) {
            await convertVideoUnit(u);
          }
        }
        final audio = demux.audio;
        if (audio != null) {
          for (final u in audio.takeFinalized(all: all)) {
            firstAudioPts ??= u.pts; // 首个带 PTS 单元（供全局基线）
            for (final frame in adts.feed(u.data.takeBytes())) {
              await aEs.add(frame);
            }
          }
        }
      }

      // ---- 分片准备流水线：读盘/解密与 demux 并行 ----
      // 旧实现在喂入循环里串行内联解密：喂第 i 片前 CPU 全耗在 AES 上（手机
      // 单核纯 Dart AES 仅 5-15MB/s），demux 干等。现在把「读 + 解密」提前
      // _prepareAhead 片启动：加密片的 AES 在 Isolate.run 子 isolate 里算，
      // 与本片的 demux/喂入及相邻片解密并行。喂入顺序与语义不变：每片喂完发
      // 一次 progress、逐块 fail-fast；第 j 片的准备错误在消费到第 j 片时经
      // await 原样抛出。
      // 内存上界：最多 1 + _prepareAhead 片明文同时存活（当前片 + 前瞻片），
      // 约 3 × 分片大小、数十 MB 级——以此换 AES 不再串行阻塞流水线。
      // 取消：主侧 Isolate.kill 杀本 worker 不会级联杀飞行中的 Isolate.run
      // 子 isolate，它们各自算完这一片后静默退出——浪费有上界
      // （≤ _prepareAhead 片解密），不做额外处理。
      final crypto = req.crypto;
      final pending = <Future<({Uint8List plain, int diskBytes})>>[];
      var nextPrepare = 0;
      void pump() {
        while (nextPrepare < segmentFiles.length &&
            pending.length <= _prepareAhead) {
          final f = _prepareSegment(segmentFiles[nextPrepare++], crypto);
          // 错误留到消费该片时经 await 抛出；不先挂 ignore 会被判定为未处理
          // 异步错误（Future 可多次监听，错误仍会送达之后的 await）。
          f.ignore();
          pending.add(f);
        }
      }

      Future<void> feedSegment(({Uint8List plain, int diskBytes}) seg) async {
        totalBytes += seg.diskBytes;
        final plain = seg.plain;
        for (var off = 0; off < plain.length; off += _feedChunkSize) {
          final end = off + _feedChunkSize < plain.length
              ? off + _feedChunkSize
              : plain.length;
          demux.feed(Uint8List.sublistView(plain, off, end));
          // PMT 一见即校验视频编码：h265 等大任务不必读完全部分片才报错
          _failFastOnPmt(demux);
          await drain(all: false);
        }
        req.reply.send({'progress': totalBytes});
      }

      pump(); // 启动第 0..=_prepareAhead 片的准备
      while (pending.isNotEmpty) {
        await feedSegment(await pending.removeAt(0));
        pump(); // 当前片明文已随 feedSegment 返回可回收，再补位下一片
      }
      demux.finish();
      await drain(all: true);
    } finally {
      await vEs.close();
      await aEs.close();
    }

    _log('input: ${segmentFiles.length} segments, $totalBytes bytes');

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

    if (demux.video == null || vType != TsStreamType.h264) {
      throw UnsupportedStreamException(
        'video codec $vCodec not supported yet (only h264)',
      );
    }
    if (demux.audio == null || aType != TsStreamType.aacAdts) {
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
    if (vtable.isEmpty) {
      throw const UnsupportedStreamException('no video frames');
    }
    _log('video: sps=${vSps.isNotEmpty} pps=${vPps.isNotEmpty} '
        'frames=${vtable.length} I=$iCount P=$pCount B=$bCount');

    final aac = adts.track;
    if (aac == null) {
      throw const UnsupportedStreamException('no decodable AAC frames');
    }
    _log('audio: frames=${aac.frameSizes.length} rate=${aac.sampleRate} '
        'ch=${aac.channels} aot=${aac.objectType}');

    final dims = parseSpsDimensions(vSps);
    _log('dimensions: ${dims.width}x${dims.height}');

    // 原子写：先流式写 .part 再 rename，进程被杀不会在最终路径留下半截 mp4。
    final partPath = '$outMp4.part';
    final built = await buildMp4(
      vsamples: vtable,
      sps: vSps,
      pps: vPps,
      width: dims.width,
      height: dims.height,
      aac: aac,
      firstAudioPts: firstAudioPts ?? vtable.first.dts,
      videoEs: vEsPath,
      audioEs: aEsPath,
      outPath: partPath,
    );

    _log('timing: firstPts=${built.firstPts} firstDts=${built.firstDts} '
        'ts=${built.videoTimescale} elst.empty=${built.emptyEditDur} '
        'elst.mediaTime=${built.mediaStart} vDur=${built.videoTotalDur} '
        'ctts[0..]=${built.firstCtts}');
    _log('boxes: mdat=${built.mdatSize} moov=${built.moovSize}');

    await File(partPath).rename(outMp4);

    sw.stop();
    _log('done: wrote ${built.fileSize} bytes in ${sw.elapsedMilliseconds}ms');
    return built.fileSize;
  } finally {
    // 成功与 worker 内失败都清掉 ES 临时文件；kill 取消（本代码不再运行）
    // 由主侧 _deletePart 兜底删除。
    for (final path in [vEsPath, aEsPath]) {
      try {
        File(path).deleteSync();
      } catch (_) {
        // 清理失败不影响转封装结果。
      }
    }
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

String _codecLabel(int t) {
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
