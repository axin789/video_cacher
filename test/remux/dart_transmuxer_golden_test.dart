import 'dart:io';
import 'dart:typed_data';

import 'package:video_cacher/src/download/hls/aes_decryptor.dart';
import 'package:video_cacher/src/log.dart';
import 'package:video_cacher/src/remux/dart_transmuxer/dart_transmuxer.dart';
import 'package:video_cacher/src/remux/remuxer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

const Set<String> _containers = {
  'moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf', //
};

void _collectTypes(Uint8List b, int start, int end, List<String> out) {
  int o = start;
  while (o + 8 <= end) {
    final size = _u32(b, o);
    final type = String.fromCharCodes(b, o + 4, o + 8);
    out.add(type);
    if (size < 8) break;
    if (_containers.contains(type)) _collectTypes(b, o + 8, o + size, out);
    o += size;
  }
}

/// 收集所有 stsz 的 sample_count。
List<int> _stszCounts(Uint8List b, int start, int end) {
  final counts = <int>[];
  void walk(int s, int e) {
    int o = s;
    while (o + 8 <= e) {
      final size = _u32(b, o);
      final type = String.fromCharCodes(b, o + 4, o + 8);
      if (type == 'stsz') counts.add(_u32(b, o + 8 + 8));
      if (size < 8) break;
      if (_containers.contains(type)) walk(o + 8, o + size);
      o += size;
    }
  }

  walk(start, end);
  return counts;
}

bool _hasFourCC(Uint8List b, String cc) {
  final t = cc.codeUnits;
  for (int i = 0; i + 4 <= b.length; i++) {
    if (b[i] == t[0] && b[i + 1] == t[1] && b[i + 2] == t[2] && b[i + 3] == t[3]) {
      return true;
    }
  }
  return false;
}

bool _hasTool(String tool) {
  try {
    return Process.runSync(tool, ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

String? _probe(String file, String entries) {
  final r = Process.runSync('ffprobe', [
    '-v', 'error', //
    '-show_entries', entries,
    '-of', 'default=noprint_wrappers=1:nokey=1',
    file,
  ]);
  return r.exitCode == 0 ? (r.stdout as String).trim() : null;
}

/// 取某一流（'v:0' 或 'a:0'）首帧的 best_effort_timestamp_time（秒）。
///
/// 用「首帧真实 PTS」而非流的 start_time：ffmpeg 的 mov muxer 会用 edit list
/// 把 start_time 规范化/trim，并非时间真理；首帧 PTS 才反映真实呈现时刻。
double _firstFramePts(String file, String stream) {
  final r = Process.runSync('ffprobe', [
    '-v', 'error', '-select_streams', stream, //
    '-show_entries', 'frame=best_effort_timestamp_time',
    '-read_intervals', '%+#1',
    '-of', 'default=noprint_wrappers=1:nokey=1',
    file,
  ]);
  // 只取第一行（首帧）。
  final first = (r.stdout as String)
      .split('\n')
      .map((l) => l.trim())
      .firstWhere((l) => l.isNotEmpty);
  return double.parse(first);
}

/// AES-128-CBC + PKCS7 整片加密（AesDecryptor.decryptCbc 的逆操作）。
Uint8List _encrypt(Uint8List plain, Uint8List key, Uint8List iv) {
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  )..init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return cipher.process(plain);
}

String _sha256Hex(Uint8List bytes) => SHA256Digest()
    .process(bytes)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

void main() {
  final fixture = File('test/fixtures/ts/h264_aac.ts');

  group('DartTransmuxer golden', () {
    late Directory tmp;
    late String outMp4;

    setUp(() async {
      VideoCacherLog.verbose = false;
      tmp = await Directory.systemTemp.createTemp('transmux_test_');
      outMp4 = '${tmp.path}/out.mp4';
    });

    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('fixture 存在', () {
      expect(fixture.existsSync(), isTrue,
          reason: '需先用 ffmpeg 生成 test/fixtures/ts/h264_aac.ts');
    });

    test('转封装产出合法 mp4（无需 ffmpeg）', () async {
      final res = await DartTransmuxer().remux(
        taskId: 't',
        segmentFiles: [fixture.path],
        outMp4: outMp4,
        dir: tmp.path,
      );
      expect(res.ok, isTrue, reason: res.error);
      final bytes = await File(outMp4).readAsBytes();

      final types = <String>[];
      _collectTypes(bytes, 0, bytes.length, types);
      // 结构完整
      expect(types, containsAll(['ftyp', 'mdat', 'moov']));
      expect(_hasFourCC(bytes, 'avcC'), isTrue);
      expect(_hasFourCC(bytes, 'esds'), isTrue);
      expect(types, contains('elst'));
      expect(types, contains('ctts')); // 含 B 帧
      expect(types, contains('stss'));
      expect(types.where((t) => t == 'trak').length, 2);

      // 非零帧数：video stsz sample_count > 0
      final counts = _stszCounts(bytes, 0, bytes.length);
      expect(counts.length, 2);
      expect(counts.every((c) => c > 0), isTrue);
    });

    test('ffprobe/framemd5 与 ffmpeg -c copy 一致（有 ffmpeg 时）', () async {
      if (!_hasTool('ffmpeg') || !_hasTool('ffprobe')) {
        // 环境无 ffmpeg：跳过深度校验（上一个用例已保证结构合法）。
        return;
      }
      final res = await DartTransmuxer().remux(
        taskId: 't',
        segmentFiles: [fixture.path],
        outMp4: outMp4,
        dir: tmp.path,
      );
      expect(res.ok, isTrue, reason: res.error);

      // ffmpeg -c copy 作为 oracle
      final ref = '${tmp.path}/ref.mp4';
      final copy = Process.runSync('ffmpeg', [
        '-v', 'error', '-i', fixture.path, //
        '-c', 'copy', '-f', 'mp4', ref, '-y',
      ]);
      expect(copy.exitCode, 0, reason: copy.stderr as String);

      // (a) 帧数一致
      final myFrames = _probe(outMp4, 'stream=nb_frames');
      final refFrames = _probe(ref, 'stream=nb_frames');
      expect(myFrames, isNotNull);
      expect(myFrames, refFrames, reason: 'nb_frames 应与 ffmpeg 一致');

      // 时长接近
      final myDur = double.parse(_probe(outMp4, 'format=duration')!);
      final refDur = double.parse(_probe(ref, 'format=duration')!);
      expect((myDur - refDur).abs() < 0.1, isTrue,
          reason: 'duration $myDur vs $refDur');

      // (a2) A/V 同步：产物必须保留「源 TS 的音画 offset」。
      // 判据不是「产物 start_time ≈ ffmpeg start_time」——ffmpeg 的 mov muxer 会
      // 用 edit list 把起始 offset 规范化/trim（真实样本上把 0.0895s 压成 0.023s），
      // 故 ffmpeg 的 start_time 并非时间真理。忠实还原的正确判据是：
      //   outOff (vOut−aOut) ≈ srcOff (vSrc−aSrc)。
      // 若呈现基线混入 DTS（含 B 帧时），视频被多延迟 (firstAudioPts−firstVideoDts)，
      // offset 就会偏离源，本断言据此拦住该回归。容差只放行 ffmpeg 音频 priming 的
      // 极小残差。
      const offTol = 300 / 90000; // ≈3.3ms
      final srcOff =
          _firstFramePts(fixture.path, 'v:0') - _firstFramePts(fixture.path, 'a:0');
      final outOff =
          _firstFramePts(outMp4, 'v:0') - _firstFramePts(outMp4, 'a:0');
      expect((outOff - srcOff).abs() < offTol, isTrue,
          reason: '音画 offset 应保留源 TS：out=$outOff src=$srcOff');

      // (b) 逐帧 framemd5：比对解码帧的内容 md5（最后一列）。
      // 只比 md5 列不比时间戳列：ffmpeg 音频 priming 会带来极小时间戳残差，
      // 但解码像素必须逐帧字节一致。
      List<String> frameMd5s(String file) {
        final md5 = '${tmp.path}/${file.hashCode}.fmd5';
        final r = Process.runSync('ffmpeg', [
          '-v', 'error', '-i', file, '-an', '-f', 'framemd5', md5, '-y',
        ]);
        expect(r.exitCode, 0, reason: r.stderr as String);
        return File(md5)
            .readAsLinesSync()
            .where((l) => !l.startsWith('#') && l.trim().isNotEmpty)
            .map((l) => l.split(',').last.trim())
            .toList();
      }

      expect(frameMd5s(outMp4), frameMd5s(ref),
          reason: '解码视频应与 ffmpeg -c copy 逐帧像素一致');
    });

    test('加密分片 + TransmuxCrypto：产物与明文 remux 逐字节一致（sha256）', () async {
      // 把 fixture 按 188 对齐拆成 2 段，模拟多分片 HLS。
      final tsBytes = fixture.readAsBytesSync();
      expect(tsBytes.length % 188, 0, reason: 'TS fixture 应为 188 字节对齐');
      final splitAt = (tsBytes.length ~/ 188 ~/ 2) * 188;
      final part0 = Uint8List.sublistView(tsBytes, 0, splitAt);
      final part1 = Uint8List.sublistView(tsBytes, splitAt);

      // 明文两段 remux（无 crypto）作为基准。
      final plain0 = File('${tmp.path}/seg_0.ts')..writeAsBytesSync(part0);
      final plain1 = File('${tmp.path}/seg_1.ts')..writeAsBytesSync(part1);
      final plainOut = '${tmp.path}/plain.mp4';
      final rPlain = await DartTransmuxer().remux(
        taskId: 'plain',
        segmentFiles: [plain0.path, plain1.path],
        outMp4: plainOut,
        dir: tmp.path,
      );
      expect(rPlain.ok, isTrue, reason: rPlain.error);

      // 同两段 AES-128-CBC 加密落 .enc（固定 key + 逐片序号 IV），
      // 带 TransmuxCrypto remux：worker 内解密必须字节透明。
      final key = Uint8List.fromList(List<int>.generate(16, (i) => i * 7 & 0xff));
      final iv0 = AesDecryptor.ivFromSequence(0);
      final iv1 = AesDecryptor.ivFromSequence(1);
      final enc0 = File('${tmp.path}/seg_0.ts.enc')
        ..writeAsBytesSync(_encrypt(part0, key, iv0));
      final enc1 = File('${tmp.path}/seg_1.ts.enc')
        ..writeAsBytesSync(_encrypt(part1, key, iv1));
      final encOut = '${tmp.path}/enc.mp4';
      final rEnc = await DartTransmuxer().remux(
        taskId: 'enc',
        segmentFiles: [enc0.path, enc1.path],
        outMp4: encOut,
        dir: tmp.path,
        crypto: TransmuxCrypto(key, {enc0.path: iv0, enc1.path: iv1}),
      );
      expect(rEnc.ok, isTrue, reason: rEnc.error);

      final plainHash = _sha256Hex(File(plainOut).readAsBytesSync());
      final encHash = _sha256Hex(File(encOut).readAsBytesSync());
      // ignore: avoid_print
      print('sha256 plain=$plainHash enc=$encHash');
      expect(encHash, plainHash, reason: '解密后置必须对产物字节透明');
    });

    test('前瞻解密流水线的错误传播：中段密文损坏 → 失败且无 .es/.part 残留', () async {
      // 3 片加密输入，第 1 片密文尾块翻转一字节 → PKCS7 去填充失败。该错误
      // 发生在前瞻子 isolate 里，必须在消费到该片时让 remux 以解密错误整体
      // 失败（收到具体错误消息，而非未处理异步错误杀掉 worker 后的
      // 'transmux worker exited'），且两遍式的中间产物已清理。
      final tsBytes = fixture.readAsBytesSync();
      final third = (tsBytes.length ~/ 188 ~/ 3) * 188;
      final parts = [
        Uint8List.sublistView(tsBytes, 0, third),
        Uint8List.sublistView(tsBytes, third, third * 2),
        Uint8List.sublistView(tsBytes, third * 2),
      ];
      final key =
          Uint8List.fromList(List<int>.generate(16, (i) => i * 7 & 0xff));
      final segs = <String>[];
      final ivByPath = <String, Uint8List>{};
      for (var i = 0; i < parts.length; i++) {
        final iv = AesDecryptor.ivFromSequence(i);
        final enc = _encrypt(parts[i], key, iv);
        if (i == 1) enc[enc.length - 1] ^= 0xff; // 破坏尾块 padding
        final f = File('${tmp.path}/bad_$i.ts.enc')..writeAsBytesSync(enc);
        segs.add(f.path);
        ivByPath[f.path] = iv;
      }
      final out = '${tmp.path}/bad.mp4';
      final res = await DartTransmuxer().remux(
        taskId: 'bad',
        segmentFiles: segs,
        outMp4: out,
        dir: tmp.path,
        crypto: TransmuxCrypto(key, ivByPath),
      );
      expect(res.ok, isFalse);
      expect(res.error, contains('pad'), reason: '应带出解密错误：${res.error}');
      for (final leftover in [out, '$out.part', '$out.v.es', '$out.a.es']) {
        expect(File(leftover).existsSync(), isFalse, reason: leftover);
      }
    });
  });
}
