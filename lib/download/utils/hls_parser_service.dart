import 'package:dio/dio.dart';
import 'package:flutter_hls_parser/flutter_hls_parser.dart' hide Segment;

import '../model/m3u8_models.dart';

class HlsParsedResult {
  final List<Segment> segments;
  final KeyInfo? key;
  final String mediaContent;
  final Uri mediaBase;
  final int mediaSequenceBase;

  HlsParsedResult({required this.segments, required this.key, required this.mediaContent, required this.mediaBase, required this.mediaSequenceBase});
}

class HlsParserService {
  final Dio dio;

  HlsParserService(this.dio);

  Future<HlsParsedResult> parseFromEntryUrl(String entryUrl) async {
    final entryUri = Uri.parse(entryUrl);
    final entryText = (await dio.get<String>(entryUrl, options: Options(responseType: ResponseType.plain))).data ?? '';

    final parser = HlsPlaylistParser.create();
    final entryPlaylist = await parser.parseString(entryUri, entryText);

    String mediaUrl = entryUrl;
    if (entryPlaylist is HlsMasterPlaylist) {
      if (entryPlaylist.variants.isEmpty) throw StateError('Master playlist has no variants.');

      // 优先选择“有视频轨且兼容性更高”的流，避免只音频或设备不兼容导致黑屏有声
      final variants = [...entryPlaylist.variants];
      variants.sort((a, b) {
        int scoreOf(Variant v) {
          final format = v.format;
          final codecs = (format.codecs ?? '').toLowerCase();
          final hasResolution = format.width != null || format.height != null;

          int score = 0;
          // 明确是 H264 轨优先（兼容最好）
          if (codecs.contains('avc1')) score += 1000;
          // 仅有视频轨信息优先
          if (hasResolution) score += 500;
          // HEVC 次优（部分设备/播放器兼容较弱）
          if (codecs.contains('hvc1') || codecs.contains('hev1')) score += 200;

          score += (format.bitrate ?? 0) ~/ 1000;
          return score;
        }

        return scoreOf(b).compareTo(scoreOf(a));
      });

      mediaUrl = variants.first.url as String;
    }
    final mediaUri = Uri.parse(mediaUrl);
    final mediaText = (await dio.get<String>(mediaUrl, options: Options(responseType: ResponseType.plain))).data ?? '';
    final mediaPlaylist = await parser.parseString(mediaUri, mediaText);
    if (mediaPlaylist is! HlsMediaPlaylist) throw StateError('Parsed playlist is not a media playlist.');

    KeyInfo? key;
    String? keyUri;
    String? ivHex;
    for (final seg in mediaPlaylist.segments) {
      if (seg.fullSegmentEncryptionKeyUri != null) {
        keyUri = seg.fullSegmentEncryptionKeyUri!;
        ivHex = seg.encryptionIV;
        break;
      }
    }
    if (keyUri != null) {
      key = KeyInfo()
        ..method = 'AES-128'
        ..uri = _absUrl(keyUri, mediaUri)
        ..localName = 'key.bin'
        ..ivHex = ivHex;
    }

    final segments = <Segment>[];
    for (int i = 0; i < mediaPlaylist.segments.length; i++) {
      final s = mediaPlaylist.segments[i];
      final abs = _absUrl(s.url!, mediaUri);
      segments.add(Segment(index: i, duration: s.durationUs ?? 0, remoteUri: abs, localName: 'seg_${(i + 1).toString().padLeft(5, '0')}.ts'));
    }
    int seqBase = 0;
    try {
      final dynamic dyn = mediaPlaylist;
      seqBase = dyn.mediaSequence ?? 0;
    } catch (_) {}
    return HlsParsedResult(segments: segments, key: key, mediaContent: mediaText, mediaBase: mediaUri, mediaSequenceBase: seqBase);
  }

  String _absUrl(String maybeRelative, Uri base) {
    final u = Uri.parse(maybeRelative);
    return u.isAbsolute ? u.toString() : base.resolveUri(u).toString();
  }
}
