import 'package:flutter/services.dart';

import '../../log.dart';

/// 系统加密库（硬件 AES）通道：Android `javax.crypto.Cipher`（Conscrypt →
/// BoringSSL）、iOS `CommonCrypto`，两者都走 ARMv8 的 AES 指令。
///
/// 纯 Dart 的 `AesDecryptor` 在真机上实测只有约 1MB/s，433MB 加密视频光解密
/// 就要 400s；系统库是 500-2000MB/s 量级。语义与 `AesDecryptor.decryptCbc`
/// 完全一致（AES-128-CBC + PKCS7 去填充），产物必须逐字节相同。
///
/// 不可用时（无原生实现的平台、`flutter test`、拿不到 token 的背景 isolate）
/// 一律返回 null，由调用方退回纯 Dart 兜底。
///
/// 用法分两侧：
///  - 根 isolate 先 [ensureAvailable] 做一次能力探测（结果缓存到进程结束）；
///  - 探测通过才把 `RootIsolateToken.instance` 交给 worker isolate，由
///    [initBackgroundIsolate] 装上 BinaryMessenger 并直接启用。
///
/// 探测必须在根 isolate 做：背景 isolate 的平台消息一旦发往不存在的宿主
/// （如 `flutter test` 的 flutter_tester），整个 isolate 会被引擎直接干掉，
/// 没有可捕获的异常。根 isolate 上同样的调用只会抛 [MissingPluginException]。
class PlatformAes {
  PlatformAes._();

  static const MethodChannel _channel = MethodChannel('video_cacher/crypto');
  static const String _method = 'aesCbcDecrypt';

  /// 可用性缓存（每个 isolate 一份静态副本）；null 表示还没定论。
  static bool? _available;

  /// 探测已通过、可直接走硬件路径。
  static bool get enabled => _available == true;

  /// 根 isolate 上的一次性能力探测：用固定向量走一次平台解密并校验明文，
  /// 既确认通道可用，也确认填充语义与纯 Dart 一致。结果缓存，重复调用不再往返。
  static Future<bool> ensureAvailable() async {
    final cached = _available;
    if (cached != null) return cached;
    try {
      final plain = await _invoke(_probeCipher, _probeKey, _probeIv);
      if (plain == null) return _available ?? false;
      if (!_sameBytes(plain, _probePlain)) {
        _disable('探测向量解密结果不匹配');
        return false;
      }
    } catch (e) {
      // 探测期间的任何意外（如未初始化 binding）都按不可用处理。
      _disable('探测失败（$e）');
      return false;
    }
    _available = true;
    return true;
  }

  /// worker isolate 侧启用：[token] 非空即代表根 isolate 已探测通过，装好
  /// BinaryMessenger 后直接启用；为空则本 isolate 全程走纯 Dart。
  static void initBackgroundIsolate(RootIsolateToken? token) {
    if (token == null) {
      _available = false;
      return;
    }
    try {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      _available = true;
    } catch (e) {
      _disable('背景 isolate 通道初始化失败（$e）');
    }
  }

  /// 走系统库解密整片密文；不可用或本次失败返回 null（调用方退回纯 Dart）。
  static Future<Uint8List?> decryptCbc(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
  ) async {
    if (!enabled) return null;
    return _invoke(data, key, iv);
  }

  static Future<Uint8List?> _invoke(
    Uint8List data,
    Uint8List key,
    Uint8List iv,
  ) async {
    try {
      return await _channel.invokeMethod<Uint8List>(_method, <String, Object>{
        'key': key,
        'iv': iv,
        'data': data,
      });
    } on MissingPluginException catch (e) {
      // 该平台没有原生实现（macOS/桌面、flutter test）：永久兜底。
      _disable('平台通道未注册（$e）');
      return null;
    } on PlatformException catch (e) {
      // 平台侧单次解密失败（如密文损坏）：本次退回纯 Dart 由它抛出真实错误，
      // 不因一片坏数据永久关掉硬件路径。
      VideoCacherLog.d('crypto', 'platform aes failed: ${e.code} ${e.message}');
      return null;
    }
  }

  /// 永久判定不可用；[_available] 只会被置一次 false，日志天然只打一次。
  static void _disable(String reason) {
    if (_available == false) return;
    _available = false;
    VideoCacherLog.d('crypto', '硬件 AES 不可用，改用纯 Dart：$reason');
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // 探测向量：由 `openssl enc -aes-128-cbc` 生成（明文 29 字节、密文 32 字节，
  // 因此也覆盖了 PKCS7 去填充）。
  static final Uint8List _probeKey =
      Uint8List.fromList(List<int>.generate(16, (i) => i));
  static final Uint8List _probeIv =
      Uint8List.fromList(List<int>.generate(16, (i) => 0x10 + i));
  static final Uint8List _probeCipher = Uint8List.fromList(<int>[
    0xf3, 0x38, 0x6a, 0xd6, 0xa8, 0xea, 0xd5, 0xcd, //
    0xa6, 0x92, 0x78, 0xf4, 0x61, 0xa5, 0x81, 0xdd,
    0x5e, 0x8c, 0xcf, 0x22, 0xf1, 0x2b, 0x0f, 0x94,
    0xd8, 0x78, 0xf8, 0xba, 0xa0, 0x7d, 0xe3, 0x9e,
  ]);
  static final Uint8List _probePlain =
      Uint8List.fromList('Hello HLS AES-128-CBC vector!'.codeUnits);
}
