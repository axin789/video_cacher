import 'dart:async';

import 'package:video_cacher/src/download/http/url_refresher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UrlRefresher single-flight', () {
    test('并发同一 taskId 只触发一次回调，5 个 Future 同解', () async {
      var calls = 0;
      final gate = Completer<String>();
      final refresher = UrlRefresher(
        callback: (id) {
          calls++;
          return gate.future;
        },
      );

      final futures =
          List.generate(5, (_) => refresher.refresh('t1')).toList();

      // 完成前只应触发一次回调。
      expect(calls, 1);

      gate.complete('https://new/t1.m3u8');
      final results = await Future.wait(futures);

      expect(calls, 1);
      expect(results, everyElement('https://new/t1.m3u8'));
    });

    test('串行调用不去重：完成后再次刷新会二次触发回调', () async {
      var calls = 0;
      final refresher = UrlRefresher(
        callback: (id) async {
          calls++;
          return 'https://new/$id?v=$calls';
        },
      );

      final a = await refresher.refresh('t1');
      final b = await refresher.refresh('t1');

      expect(calls, 2);
      expect(a, isNot(b));
    });

    test('不同 taskId 各自单飞，每个 id 触发一次', () async {
      var calls = 0;
      final gate1 = Completer<String>();
      final gate2 = Completer<String>();
      final refresher = UrlRefresher(
        callback: (id) {
          calls++;
          return id == 't1' ? gate1.future : gate2.future;
        },
      );

      final f1a = refresher.refresh('t1');
      final f1b = refresher.refresh('t1');
      final f2a = refresher.refresh('t2');

      expect(calls, 2);

      gate1.complete('u1');
      gate2.complete('u2');

      expect(await f1a, 'u1');
      expect(await f1b, 'u1');
      expect(await f2a, 'u2');
    });
  });

  group('UrlRefresher retry', () {
    test('首次抛错、第二次成功 -> 共 2 次尝试后返回', () async {
      var attempts = 0;
      final refresher = UrlRefresher(
        backoff: Duration.zero,
        callback: (id) async {
          attempts++;
          if (attempts == 1) throw Exception('boom');
          return 'https://ok/$id';
        },
      );

      final url = await refresher.refresh('t1');
      expect(url, 'https://ok/t1');
      expect(attempts, 2);
    });

    test('返回空白串视为失败并重试', () async {
      var attempts = 0;
      final refresher = UrlRefresher(
        backoff: Duration.zero,
        callback: (id) async {
          attempts++;
          if (attempts == 1) return '   ';
          return 'https://ok/$id';
        },
      );

      final url = await refresher.refresh('t1');
      expect(url, 'https://ok/t1');
      expect(attempts, 2);
    });

    test('始终失败 -> maxRetries+1 次尝试后抛 UrlRefreshFailedException', () async {
      var attempts = 0;
      final refresher = UrlRefresher(
        maxRetries: 3,
        backoff: Duration.zero,
        callback: (id) async {
          attempts++;
          throw Exception('always');
        },
      );

      await expectLater(
        refresher.refresh('t1'),
        throwsA(isA<UrlRefreshFailedException>()),
      );
      expect(attempts, 4); // maxRetries(3) + 1
    });

    test('maxRetries=0 时只尝试一次', () async {
      var attempts = 0;
      final refresher = UrlRefresher(
        maxRetries: 0,
        backoff: Duration.zero,
        callback: (id) async {
          attempts++;
          throw Exception('nope');
        },
      );

      await expectLater(
        refresher.refresh('t1'),
        throwsA(isA<UrlRefreshFailedException>()),
      );
      expect(attempts, 1);
    });
  });

  group('UrlRefresher callback registration', () {
    test('未注入回调 -> 抛 NoRefreshCallbackException', () async {
      final refresher = UrlRefresher();
      await expectLater(
        refresher.refresh('t1'),
        throwsA(isA<NoRefreshCallbackException>()),
      );
    });

    test('可在构造后注入回调', () async {
      final refresher = UrlRefresher(backoff: Duration.zero);
      refresher.callback = (id) async => 'https://later/$id';
      expect(refresher.hasCallback, isTrue);
      expect(await refresher.refresh('t1'), 'https://later/t1');
    });

    test('失败完成后清除在途条目：可再次发起并成功', () async {
      var calls = 0;
      final refresher = UrlRefresher(
        maxRetries: 0,
        backoff: Duration.zero,
        callback: (id) async {
          calls++;
          if (calls == 1) throw Exception('first fails');
          return 'https://recovered/$id';
        },
      );

      await expectLater(
        refresher.refresh('t1'),
        throwsA(isA<UrlRefreshFailedException>()),
      );
      expect(await refresher.refresh('t1'), 'https://recovered/t1');
      expect(calls, 2);
    });
  });
}
