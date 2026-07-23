import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_cacher/src/api/video_cacher.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假 path_provider：返回临时目录并计数，拖一拍制造并发窗口。
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.docsPath);

  final String docsPath;
  int calls = 0;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    calls++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return docsPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakePathProvider fake;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vc_init_');
    fake = _FakePathProvider(root.path);
    PathProviderPlatform.instance = fake;
  });

  tearDown(() async {
    await VideoCacher.instance.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('并发两次 ensureInitialized 共享同一次初始化，不双重装配', () async {
    final f1 = VideoCacher.instance.ensureInitialized();
    final f2 = VideoCacher.instance.ensureInitialized();
    expect(identical(f1, f2), isTrue, reason: '在飞期间应返回同一个 Future');

    await Future.wait([f1, f2]);
    expect(fake.calls, 1, reason: '初始化只应执行一次');
  });

  test('dispose 后可重新初始化', () async {
    await VideoCacher.instance.ensureInitialized();
    await VideoCacher.instance.dispose();

    await VideoCacher.instance.ensureInitialized();
    expect(fake.calls, 2, reason: 'dispose 清掉在飞守卫后应重新初始化');
  });
}
