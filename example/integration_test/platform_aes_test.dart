import 'dart:isolate';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pointycastle/export.dart';
import 'package:video_cacher/src/download/hls/aes_decryptor.dart';
import 'package:video_cacher/src/download/hls/platform_aes.dart';

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

/// 生产路径的复刻：worker isolate 用主侧传来的 token 开通平台通道后解密。
Future<void> _isolateDecrypt(List<Object?> args) async {
  final reply = args[0] as SendPort;
  final token = args[1] as RootIsolateToken?;
  final data = args[2] as Uint8List;
  final key = args[3] as Uint8List;
  final iv = args[4] as Uint8List;
  PlatformAes.initBackgroundIsolate(token);
  reply.send(<Object?>[
    PlatformAes.enabled,
    await PlatformAes.decryptCbc(data, key, iv),
  ]);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final rnd = Random(20260724);
  Uint8List randomBytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));

  testWidgets('平台通道可用（硬件 AES 已注册）', (tester) async {
    expect(await PlatformAes.ensureAvailable(), isTrue);
  });

  testWidgets('平台 AES 与 pointycastle 逐字节一致（随机数据，含各种长度）',
      (tester) async {
    expect(await PlatformAes.ensureAvailable(), isTrue);
    // 覆盖整块填充（16 的倍数）、非整块与 MB 级大片。
    // 长度 0 不测：pointycastle 的 PaddedBlockCipherImpl 自身构造不出空明文密文。
    for (final len in <int>[1, 15, 16, 17, 4096, 1 << 20]) {
      final key = randomBytes(16);
      final iv = randomBytes(16);
      final plain = randomBytes(len);
      final ct = _encrypt(plain, key, iv);

      final viaPlatform = await PlatformAes.decryptCbc(ct, key, iv);
      final viaDart = AesDecryptor.decryptCbc(ct, key, iv);
      expect(viaPlatform, isNotNull, reason: 'len=$len 平台侧不该返回 null');
      expect(viaPlatform, viaDart, reason: 'len=$len 两条路径必须逐字节一致');
      expect(viaDart, plain, reason: 'len=$len 去填充后应还原明文');
    }
  });

  testWidgets('背景 isolate 经 RootIsolateToken 也能走平台通道', (tester) async {
    expect(await PlatformAes.ensureAvailable(), isTrue);
    final key = randomBytes(16);
    final iv = randomBytes(16);
    final plain = randomBytes(256 * 1024);
    final ct = _encrypt(plain, key, iv);

    final port = ReceivePort();
    await Isolate.spawn(_isolateDecrypt,
        <Object?>[port.sendPort, RootIsolateToken.instance, ct, key, iv]);
    final res = await port.first as List<Object?>;
    port.close();

    expect(res[0], isTrue, reason: '背景 isolate 应启用硬件路径');
    expect(res[1], plain, reason: '背景 isolate 解密结果必须与明文一致');
  });
}
