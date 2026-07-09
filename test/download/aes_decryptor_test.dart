import 'dart:typed_data';

import 'package:ffmpeg_remux/src/download/hls/aes_decryptor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 用 pointycastle 加密（AES-128-CBC + PKCS7），供 round-trip 测试构造密文。
Uint8List _encrypt(List<int> plain, List<int> key, List<int> iv) {
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  )..init(
      true,
      PaddedBlockCipherParameters<CipherParameters, CipherParameters>(
        ParametersWithIV<KeyParameter>(
          KeyParameter(Uint8List.fromList(key)),
          Uint8List.fromList(iv),
        ),
        null,
      ),
    );
  return cipher.process(Uint8List.fromList(plain));
}

void main() {
  final aes = AesDecryptor();

  test('1a. 独立 openssl 向量：解密得到期望明文并去 PKCS7 填充', () {
    // 由 `openssl enc -aes-128-cbc` 生成，非本代码产出。
    final key = _hex('000102030405060708090a0b0c0d0e0f');
    final iv = _hex('101112131415161718191a1b1c1d1e1f');
    final ciphertext =
        _hex('f3386ad6a8ead5cda69278f461a581dd5e8ccf22f12b0f94d878f8baa07de39e');
    final expected = _hex('48656c6c6f20484c53204145532d3132382d43424320766563746f7221');

    final plain = aes.decrypt(ciphertext, key: key, iv: iv);
    expect(plain, expected);
    // 明文 29 字节，密文 32 字节：PKCS7 填充确实被去掉。
    expect(plain.length, 29);
  });

  test('1b. round-trip：pointycastle 加密后 decrypt 还原（覆盖整块填充）', () {
    final key = _hex('00112233445566778899aabbccddeeff');
    final iv = _hex('0f0e0d0c0b0a09080706050403020100');
    // 恰好 16 字节：PKCS7 会追加一整块 0x10 填充。
    final plain = Uint8List.fromList(List<int>.generate(16, (i) => i));
    final ct = _encrypt(plain, key, iv);
    expect(ct.length, 32);
    expect(aes.decrypt(ct, key: key, iv: iv), plain);
  });

  test('2a. ivFromHex：32 位十六进制 → 16 字节', () {
    expect(
      AesDecryptor.ivFromHex('101112131415161718191a1b1c1d1e1f'),
      _hex('101112131415161718191a1b1c1d1e1f'),
    );
    // 兼容 0x 前缀。
    expect(
      AesDecryptor.ivFromHex('0x00000000000000000000000000000001'),
      _hex('00000000000000000000000000000001'),
    );
  });

  test('2b. ivFromSequence：大端表示，低位在末尾', () {
    expect(AesDecryptor.ivFromSequence(0), Uint8List(16));
    expect(
      AesDecryptor.ivFromSequence(1),
      _hex('00000000000000000000000000000001'),
    );
    expect(
      AesDecryptor.ivFromSequence(258), // 0x0102
      _hex('00000000000000000000000000000102'),
    );
  });

  test('3. key/iv 长度非法抛 ArgumentError', () {
    final data = Uint8List(16);
    expect(
      () => aes.decrypt(data, key: Uint8List(8), iv: Uint8List(16)),
      throwsArgumentError,
    );
    expect(
      () => aes.decrypt(data, key: Uint8List(16), iv: Uint8List(15)),
      throwsArgumentError,
    );
    expect(() => AesDecryptor.ivFromHex('00'), throwsArgumentError);
  });
}
