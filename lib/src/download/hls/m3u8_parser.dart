// 轻量 m3u8 解析器：字符串 → 结构化模型。纯解析，无网络/无文件 IO。
//
// 只覆盖生产实际用到的标签：`#EXT-X-STREAM-INF`（master 选流）、
// `#EXTINF` / `#EXT-X-KEY` / `#EXT-X-MEDIA-SEQUENCE` /
// `#EXT-X-TARGETDURATION` / `#EXT-X-ENDLIST`（media）。
// 不支持但会「记录」的特性（key 轮换 / 非 AES-128 加密 / EXT-X-MAP /
// EXT-X-BYTERANGE / EXT-X-DISCONTINUITY）以标志位暴露，由下载器 fail-fast。
// 其余未知标签一律忽略。不是完整 HLS 规范实现。

/// playlist 使用了当前实现不支持的特性时由下载器抛出（下任何分片前 fail-fast）。
class UnsupportedPlaylistException implements Exception {
  final String message;

  const UnsupportedPlaylistException(this.message);

  @override
  String toString() => 'UnsupportedPlaylistException: $message';
}

/// AES 加密信息（单 key 场景）。
class HlsKey {
  /// 加密方法，如 `AES-128`；无加密为 `NONE`。
  final String method;

  /// 已归一为绝对地址的 key URI；`METHOD=NONE` 时为 null。
  final String? uri;

  /// 32 位十六进制 IV（去掉 `0x` 前缀、小写）；未显式给出时为 null。
  final String? ivHex;

  const HlsKey({required this.method, this.uri, this.ivHex});

  /// 是否需要解密。
  bool get isEncrypted => method != 'NONE';
}

/// media 播放列表中的单个分片。
class HlsSegment {
  /// 在列表中的 0-based 位置。
  final int index;

  /// `EXT-X-MEDIA-SEQUENCE` + [index]；key 未给 IV 时用作隐式 IV。
  final int mediaSequence;

  /// 已归一为绝对地址的分片 URI。
  final String uri;

  /// 由 `EXTINF` 秒数换算的毫秒数（四舍五入）。
  final int durationMs;

  const HlsSegment({
    required this.index,
    required this.mediaSequence,
    required this.uri,
    required this.durationMs,
  });
}

/// master 播放列表中的一路码流。
class HlsVariant {
  final int bandwidth;

  /// 分辨率字符串，如 `1920x1080`；缺省为 null。
  final String? resolution;

  /// 已归一为绝对地址的变体 URI。
  final String uri;

  const HlsVariant({
    required this.bandwidth,
    this.resolution,
    required this.uri,
  });
}

/// 解析结果。master 与 media 二选一。
class M3u8Playlist {
  final bool isMaster;
  final List<HlsVariant> variants;
  final List<HlsSegment> segments;

  /// media 的（单）key；无 `EXT-X-KEY` 或 `METHOD=NONE` 时为 null。
  final HlsKey? key;

  /// 是否含 `EXT-X-ENDLIST`（VOD）。
  final bool hasEndList;

  /// `EXT-X-TARGETDURATION` 换算的毫秒数；缺省为 0。
  final int targetDurationMs;

  /// 是否出现多个不同值的 `EXT-X-KEY`（key 轮换）；当前不支持。
  final bool hasKeyRotation;

  /// 出现过的非 NONE/AES-128 加密 METHOD（如 SAMPLE-AES）；没有则为 null。
  final String? unsupportedKeyMethod;

  /// 是否含 `EXT-X-MAP`（fMP4 初始化段）；当前仅支持 TS 分片。
  final bool hasMap;

  /// 是否含 `EXT-X-BYTERANGE`（字节区间分片）；当前不支持。
  final bool hasByteRange;

  /// 是否含 `EXT-X-DISCONTINUITY`（编码不连续点）；当前不支持。
  final bool hasDiscontinuity;

  const M3u8Playlist({
    required this.isMaster,
    required this.variants,
    required this.segments,
    required this.key,
    required this.hasEndList,
    required this.targetDurationMs,
    this.hasKeyRotation = false,
    this.unsupportedKeyMethod,
    this.hasMap = false,
    this.hasByteRange = false,
    this.hasDiscontinuity = false,
  });

  /// master 场景下带宽最高的一路；无变体时为 null。
  HlsVariant? get bestVariant {
    if (variants.isEmpty) return null;
    return variants
        .reduce((a, b) => b.bandwidth > a.bandwidth ? b : a);
  }
}

class M3u8Parser {
  /// 解析 [content]；[baseUri] 为该播放列表的来源地址，用于归一相对 URI。
  M3u8Playlist parse(String content, {required String baseUri}) {
    final base = Uri.parse(baseUri);
    final lines = content
        .split('\n')
        .map((l) => l.replaceAll('\r', '').trim())
        .toList();

    final variants = <HlsVariant>[];
    final segments = <HlsSegment>[];
    HlsKey? key;
    String? firstKeyValue;
    var hasKeyRotation = false;
    String? unsupportedKeyMethod;
    var hasMap = false;
    var hasByteRange = false;
    var hasDiscontinuity = false;
    var hasEndList = false;
    var targetDurationMs = 0;
    var mediaSequence = 0;

    // 待消费的、由 tag 提供的"下一行 URI"上下文。
    int? pendingBandwidth;
    String? pendingResolution;
    var expectVariantUri = false;

    int? pendingDurationMs;

    for (final line in lines) {
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          final attrs = _parseAttributes(line.substring(18));
          pendingBandwidth =
              int.tryParse(attrs['BANDWIDTH'] ?? '') ?? 0;
          pendingResolution = attrs['RESOLUTION'];
          expectVariantUri = true;
        } else if (line.startsWith('#EXTINF:')) {
          pendingDurationMs = _parseExtInf(line.substring(8));
        } else if (line.startsWith('#EXT-X-KEY:')) {
          final value = line.substring(11);
          // 多个不同值的 KEY = key 轮换：单 key 解密会把部分分片解错。
          if (firstKeyValue != null && value != firstKeyValue) {
            hasKeyRotation = true;
          }
          firstKeyValue ??= value;
          key = _parseKey(value, base);
          if (key.method != 'NONE' && key.method != 'AES-128') {
            unsupportedKeyMethod = key.method;
          }
        } else if (line.startsWith('#EXT-X-MAP:')) {
          hasMap = true;
        } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
          hasByteRange = true;
        } else if (line == '#EXT-X-DISCONTINUITY') {
          hasDiscontinuity = true;
        } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
          mediaSequence =
              int.tryParse(line.substring(22).trim()) ?? 0;
        } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
          final secs = double.tryParse(line.substring(22).trim()) ?? 0;
          targetDurationMs = (secs * 1000).round();
        } else if (line == '#EXT-X-ENDLIST') {
          hasEndList = true;
        }
        // 其余 tag（含 #EXTM3U、#EXT-X-VERSION 等）忽略。
        continue;
      }

      // 非注释行 = URI，消费最近的 tag 上下文。
      final resolved = _resolve(base, line);
      if (expectVariantUri) {
        variants.add(HlsVariant(
          bandwidth: pendingBandwidth ?? 0,
          resolution: pendingResolution,
          uri: resolved,
        ));
        expectVariantUri = false;
        pendingBandwidth = null;
        pendingResolution = null;
      } else {
        final idx = segments.length;
        segments.add(HlsSegment(
          index: idx,
          mediaSequence: mediaSequence + idx,
          uri: resolved,
          durationMs: pendingDurationMs ?? 0,
        ));
        pendingDurationMs = null;
      }
    }

    final isMaster = variants.isNotEmpty && segments.isEmpty;
    return M3u8Playlist(
      isMaster: isMaster,
      variants: variants,
      segments: segments,
      key: (key != null && key.isEncrypted) ? key : null,
      hasEndList: hasEndList,
      targetDurationMs: targetDurationMs,
      hasKeyRotation: hasKeyRotation,
      unsupportedKeyMethod: unsupportedKeyMethod,
      hasMap: hasMap,
      hasByteRange: hasByteRange,
      hasDiscontinuity: hasDiscontinuity,
    );
  }

  /// 归一：绝对 URI 原样返回；相对 URI 用 [base] 解析。
  /// 用 [Uri.resolve] 保证签名 query（含 `~ & = _`）不被破坏。
  static String _resolve(Uri base, String ref) {
    return base.resolve(ref).toString();
  }

  /// `#EXTINF:10.566667,标题` → 毫秒。逗号后标题忽略。
  static int _parseExtInf(String value) {
    final comma = value.indexOf(',');
    final numPart = (comma >= 0 ? value.substring(0, comma) : value).trim();
    final secs = double.tryParse(numPart) ?? 0;
    return (secs * 1000).round();
  }

  /// 解析 `#EXT-X-KEY` 属性并归一 URI。
  static HlsKey _parseKey(String value, Uri base) {
    final attrs = _parseAttributes(value);
    final method = (attrs['METHOD'] ?? 'NONE').toUpperCase() == 'NONE'
        ? 'NONE'
        : attrs['METHOD']!;
    if (method == 'NONE') return const HlsKey(method: 'NONE');

    final rawUri = attrs['URI'];
    final uri = (rawUri != null && rawUri.isNotEmpty)
        ? _resolve(base, rawUri)
        : null;

    String? ivHex = attrs['IV'];
    if (ivHex != null) {
      if (ivHex.toLowerCase().startsWith('0x')) ivHex = ivHex.substring(2);
      ivHex = ivHex.toLowerCase();
    }

    return HlsKey(method: method, uri: uri, ivHex: ivHex);
  }

  /// 解析逗号分隔的 `KEY=VALUE` 属性列表，支持双引号包裹的值。
  ///
  /// 关键：引号内的逗号（签名 URI 里可能出现）不作分隔符；引号内的等号
  /// 也不当作 key/value 分隔。解析完成后去掉包裹值的双引号。
  static Map<String, String> _parseAttributes(String input) {
    final result = <String, String>{};
    final buf = StringBuffer();
    final parts = <String>[];
    var inQuotes = false;

    for (var i = 0; i < input.length; i++) {
      final c = input[i];
      if (c == '"') {
        inQuotes = !inQuotes;
        buf.write(c);
      } else if (c == ',' && !inQuotes) {
        parts.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) parts.add(buf.toString());

    for (final part in parts) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final k = part.substring(0, eq).trim();
      var v = part.substring(eq + 1).trim();
      if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
        v = v.substring(1, v.length - 1);
      }
      if (k.isNotEmpty) result[k] = v;
    }
    return result;
  }
}
