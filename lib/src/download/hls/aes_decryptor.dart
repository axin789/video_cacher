import 'dart:typed_data';

// 按需导入代替 export.dart 全家桶，避免把用不到的算法钉进 AOT 产物。
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';

/// HLS 分片解密器：AES-128-CBC + PKCS7 去填充。
///
/// 与 `openssl aes-128-cbc -d` 一致（HLS 分片正是这样加密的）：整片密文一次性
/// 解密，最后一块的 PKCS7 填充被移除。key 与 iv 均为 16 字节。
class AesDecryptor {
  /// 解密整片密文，返回去填充后的明文。
  ///
  /// [key] / [iv] 必须为 16 字节，否则抛 [ArgumentError]。
  Uint8List decrypt(
    List<int> ciphertext, {
    required List<int> key,
    required List<int> iv,
  }) =>
      decryptCbc(ciphertext, key, iv);

  /// 静态核心：实例 API 与下载器的 isolate 闭包共用。cipher 在本函数内部
  /// 构造——pointycastle 对象不跨 isolate，闭包只能捕获纯字节再进来现建。
  static Uint8List decryptCbc(
    List<int> ciphertext,
    List<int> key,
    List<int> iv,
  ) {
    if (key.length != 16) {
      throw ArgumentError.value(key.length, 'key.length', 'AES-128 key 需 16 字节');
    }
    if (iv.length != 16) {
      throw ArgumentError.value(iv.length, 'iv.length', 'AES-128 iv 需 16 字节');
    }

    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      false, // decrypt
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(
          KeyParameter(_asU8(key)),
          _asU8(iv),
        ),
        null,
      ),
    );

    return cipher.process(_asU8(ciphertext));
  }

  /// 已是 Uint8List 就直接透传，不再多拷一份。
  static Uint8List _asU8(List<int> l) =>
      l is Uint8List ? l : Uint8List.fromList(l);

  /// 32 位十六进制字符串 → 16 字节 IV（`EXT-X-KEY` 显式给 IV 时用）。
  static Uint8List ivFromHex(String hex) {
    var h = hex.trim();
    if (h.toLowerCase().startsWith('0x')) h = h.substring(2);
    if (h.length != 32) {
      throw ArgumentError.value(hex, 'hex', 'IV 需 32 位十六进制字符');
    }
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  /// 媒体序号 → 16 字节大端 IV（`EXT-X-KEY` 未给 IV 时按 HLS 规范用序号）。
  static Uint8List ivFromSequence(int mediaSequence) {
    final out = Uint8List(16);
    var v = mediaSequence;
    // 大端：低位填在末尾，向前进位。
    for (var i = 15; i >= 0 && v != 0; i--) {
      out[i] = v & 0xff;
      v >>= 8;
    }
    return out;
  }
}
