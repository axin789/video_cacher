import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:video_cacher/src/api/models/download_config.dart';
import 'package:video_cacher/src/api/models/download_task.dart';
import 'package:video_cacher/src/api/models/task_event.dart';
import 'package:video_cacher/src/api/models/task_status.dart';
import 'package:video_cacher/src/download/download_engine.dart';
import 'package:video_cacher/src/download/hls/hls_downloader.dart';
import 'package:video_cacher/src/download/http/http_client.dart';
import 'package:video_cacher/src/download/http/url_refresher.dart';
import 'package:video_cacher/src/download/mp4/mp4_downloader.dart';
import 'package:video_cacher/src/remux/remuxer.dart';
import 'package:video_cacher/src/store/memory_task_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 路由式假适配器：拿到 RequestOptions 与 cancelFuture 自行决定返回什么。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions o, Future<void>? cancel)
      handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options, cancelFuture);

  @override
  void close({bool force = false}) {}
}

ResponseBody _bytesBody(
  int status,
  List<int> body, {
  Map<String, List<String>> headers = const {},
}) =>
    ResponseBody.fromBytes(Uint8List.fromList(body), status, headers: headers);

List<int> _range(int start, int end) =>
    List<int>.generate(end - start, (i) => (start + i) % 256);

/// 假 remuxer：默认成功即产出 outMp4；可注入 [gate] 卡住 remux（cancel 时放行），
/// 或 [ok]=false 模拟失败；[reportProgress] 时按输入字节回报两笔递增进度。
/// 记录 cleanup / cancel 调用。
class _FakeRemuxer implements Remuxer {
  _FakeRemuxer({this.ok = true, this.gate, this.reportProgress = false});

  final bool ok;
  final Completer<void>? gate;
  final bool reportProgress;
  int cleanupCalls = 0;
  final List<String> canceled = [];

  @override
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles,
    required String outMp4,
    required String dir,
    void Function(int bytes)? onProgress,
  }) async {
    if (gate != null) await gate!.future;
    if (reportProgress) {
      var total = 0;
      for (final f in segmentFiles) {
        total += File(f).lengthSync();
      }
      onProgress?.call(total ~/ 2);
      onProgress?.call(total);
    }
    if (!ok) return const RemuxResult(ok: false, error: 'remux boom');
    File(outMp4).writeAsBytesSync(const [0, 1, 2, 3]);
    return RemuxResult(ok: true, outMp4: outMp4);
  }

  @override
  void cancel(String taskId) {
    canceled.add(taskId);
    if (gate != null && !gate!.isCompleted) gate!.complete();
  }

  @override
  Future<void> cleanup({
    required String dir,
    required String? outMp4,
    required bool success,
  }) async {
    cleanupCalls++;
  }
}

Mp4Downloader _mp4Dl(_FakeAdapter a, {RefreshUrlCallback? refresh}) {
  final dio = Dio()..httpClientAdapter = a;
  return Mp4Downloader(
    http: HttpClient(const DownloadConfig(), dio: dio),
    refresher: UrlRefresher(callback: refresh, backoff: Duration.zero),
  );
}

HlsDownloader _hlsDl(_FakeAdapter a, {RefreshUrlCallback? refresh}) {
  final dio = Dio()..httpClientAdapter = a;
  return HlsDownloader(
    http: HttpClient(const DownloadConfig(), dio: dio),
    refresher: UrlRefresher(callback: refresh, backoff: Duration.zero),
  );
}

/// 不参与本用例的一侧下载器占位（永远 404）。
_FakeAdapter _idleAdapter() =>
    _FakeAdapter((o, c) async => _bytesBody(404, const []));

void _noopProgress(int a, int b) {}

/// 在 download 返回给引擎前注入动作：确定性模拟 cancel/pause 恰好落在
/// 下载完成与引擎后续提交之间的续段窗口。
class _HookedMp4Downloader extends Mp4Downloader {
  _HookedMp4Downloader({
    required super.http,
    required super.refresher,
    required this.beforeReturn,
  });

  final void Function(String taskId) beforeReturn;

  @override
  Future<Mp4DownloadResult> download({
    required String taskId,
    required String url,
    required String destPath,
    String? partPath,
    String? knownEtag,
    void Function(String? etag)? onEtag,
    void Function(int downloaded, int total) onProgress = _noopProgress,
    CancelToken? cancelToken,
  }) async {
    final r = await super.download(
      taskId: taskId,
      url: url,
      destPath: destPath,
      partPath: partPath,
      knownEtag: knownEtag,
      onEtag: onEtag,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    beforeReturn(taskId);
    return r;
  }
}

/// 同上，HLS 版：动作落在下载完成与 remuxing 提交之间的窗口。
class _HookedHlsDownloader extends HlsDownloader {
  _HookedHlsDownloader({
    required super.http,
    required super.refresher,
    required this.beforeReturn,
  });

  final void Function(String taskId) beforeReturn;

  @override
  Future<HlsDownloadResult> download({
    required String taskId,
    required String entryUrl,
    required String dir,
    void Function(int done, int total) onProgress = _noopProgress,
    CancelToken? cancelToken,
  }) async {
    final r = await super.download(
      taskId: taskId,
      entryUrl: entryUrl,
      dir: dir,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    beforeReturn(taskId);
    return r;
  }
}

const String _hlsPlaylist = '#EXTM3U\n'
    '#EXT-X-VERSION:3\n'
    '#EXT-X-TARGETDURATION:4\n'
    '#EXT-X-MEDIA-SEQUENCE:0\n'
    '#EXTINF:4.0,\nseg0.ts\n'
    '#EXTINF:4.0,\nseg1.ts\n'
    '#EXTINF:4.0,\nseg2.ts\n'
    '#EXT-X-ENDLIST\n';

/// 未加密 3 片 HLS 适配器。
_FakeAdapter _hlsAdapter() => _FakeAdapter((o, c) async {
      final url = o.uri.toString();
      if (url.endsWith('/index.m3u8')) {
        return _bytesBody(200, _hlsPlaylist.codeUnits);
      }
      if (url.endsWith('/seg0.ts')) return _bytesBody(200, _range(0, 10));
      if (url.endsWith('/seg1.ts')) return _bytesBody(200, _range(10, 20));
      if (url.endsWith('/seg2.ts')) return _bytesBody(200, _range(20, 30));
      return _bytesBody(404, const []);
    });

/// 按 url 子串匹配 gate 的 mp4 适配器：GET 阻塞在对应 Completer 上，放行后吐全量。
_FakeAdapter _gatedMp4Adapter(Map<String, Completer<void>> gates) =>
    _FakeAdapter((o, c) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['50'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      final url = o.uri.toString();
      final gate = gates.entries.firstWhere((e) => url.contains(e.key)).value;
      Stream<Uint8List> gated() async* {
        await gate.future;
        yield Uint8List.fromList(_range(0, 50));
      }

      return ResponseBody(gated(), 200, headers: {
        'content-length': ['50'],
      });
    });

DownloadTask _task(
  String id, {
  required SourceKind kind,
  required String url,
  required String dir,
}) =>
    DownloadTask(
      taskId: id,
      movieId: id,
      name: id,
      coverImg: '',
      url: url,
      dir: dir,
      kind: kind,
      createdAtMs: 0,
    );

/// 记录事件流，并支持 await 满足谓词的事件。
class _Recorder {
  _Recorder(DownloadEngine e) {
    _sub = e.events.listen((ev) {
      events.add(ev);
      (seq[ev.taskId] ??= []).add(ev.status);
      _waiters.removeWhere((w) {
        if (w.test(ev)) {
          w.completer.complete();
          return true;
        }
        return false;
      });
    });
  }

  final List<TaskEvent> events = [];
  final Map<String, List<TaskStatus>> seq = {};
  final List<({bool Function(TaskEvent) test, Completer<void> completer})>
      _waiters = [];
  late final StreamSubscription<TaskEvent> _sub;

  Future<void> waitWhere(bool Function(TaskEvent) test) {
    if (events.any(test)) return Future.value();
    final c = Completer<void>();
    _waiters.add((test: test, completer: c));
    return c.future;
  }

  Future<void> wait(String id, TaskStatus s) =>
      waitWhere((ev) => ev.taskId == id && ev.status == s);

  /// 去重后的状态转移序列（相邻重复合并）。
  List<TaskStatus> transitions(String id) {
    final out = <TaskStatus>[];
    for (final s in seq[id] ?? const <TaskStatus>[]) {
      if (out.isEmpty || out.last != s) out.add(s);
    }
    return out;
  }

  Future<void> dispose() => _sub.cancel();
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('engine_');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  String mkDir(String name) {
    final d = Directory('${root.path}/$name')..createSync(recursive: true);
    return d.path;
  }

  test('1. mp4 happy path: queued→running→completed, mp4Path 落地', () async {
    final full = _range(0, 200);
    final adapter = _FakeAdapter((o, c) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['200'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      return _bytesBody(200, full, headers: {
        'content-length': ['200'],
      });
    });
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    final dir = mkDir('t1');
    engine.submit(_task('t1',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: dir));
    await rec.wait('t1', TaskStatus.completed);

    final t = engine.tasks['t1']!;
    expect(t.status, TaskStatus.completed);
    expect(t.mp4Path, '$dir/video.mp4');
    expect(File(t.mp4Path!).readAsBytesSync(), full);
    expect(rec.transitions('t1'),
        [TaskStatus.queued, TaskStatus.running, TaskStatus.completed]);

    final stored = (await store.loadAll()).firstWhere((e) => e.taskId == 't1');
    expect(stored.status, TaskStatus.completed);

    await rec.dispose();
    await engine.dispose();
  });

  test('2. hls happy path: ...→running→remuxing→completed, cleanup 被调',
      () async {
    final remuxer = _FakeRemuxer();
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _hlsDl(_hlsAdapter()),
      remuxer: remuxer,
    );
    final rec = _Recorder(engine);

    final dir = mkDir('t2');
    engine.submit(_task('t2',
        kind: SourceKind.hls,
        url: 'https://cdn/hls/index.m3u8',
        dir: dir));
    await rec.wait('t2', TaskStatus.completed);

    final t = engine.tasks['t2']!;
    expect(t.status, TaskStatus.completed);
    expect(t.mp4Path, '$dir/video.mp4');
    expect(File(t.mp4Path!).existsSync(), isTrue);
    expect(remuxer.cleanupCalls, 1);
    expect(
      rec.transitions('t2'),
      [
        TaskStatus.queued,
        TaskStatus.running,
        TaskStatus.remuxing,
        TaskStatus.completed
      ],
    );

    await rec.dispose();
    await engine.dispose();
  });

  test('3. pause: 活跃任务→paused(非 failed)，token 取消；resume 后跑到 completed',
      () async {
    var attempt = 0;
    final adapter = _FakeAdapter((o, cancel) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      attempt++;
      if (attempt == 1) {
        // 首次：吐 30 字节后等 token 取消再以 cancel 中断，保留 .part。
        final controller = StreamController<Uint8List>();
        controller.add(Uint8List.fromList(_range(0, 30)));
        cancel?.then((_) {
          if (!controller.isClosed) {
            controller.addError(DioException(
                requestOptions: o, type: DioExceptionType.cancel));
            controller.close();
          }
        });
        return ResponseBody(controller.stream, 200, headers: {
          'content-length': ['100'],
        });
      }
      // 续传：直接回 200 全量。
      return _bytesBody(200, _range(0, 100), headers: {
        'content-length': ['100'],
      });
    });
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    final dir = mkDir('t3');
    engine.submit(_task('t3',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: dir));
    await rec.wait('t3', TaskStatus.running);
    // 等首个分块真正落地，确保 GET 流已建立（避免 pause 落在 HEAD 阶段导致首个 GET 被跳过）。
    await rec.waitWhere((ev) => ev.taskId == 't3' && ev.downloadedBytes > 0);

    engine.pause('t3');
    await rec.wait('t3', TaskStatus.paused);
    expect(engine.tasks['t3']!.status, TaskStatus.paused);
    expect(rec.seq['t3']!.contains(TaskStatus.failed), isFalse);

    engine.resume('t3');
    await rec.wait('t3', TaskStatus.completed);
    final t = engine.tasks['t3']!;
    expect(t.status, TaskStatus.completed);
    expect(File(t.mp4Path!).readAsBytesSync(), _range(0, 100));

    await rec.dispose();
    await engine.dispose();
  });

  test('4. cancel: 活跃任务→canceled(非 failed)', () async {
    final adapter = _FakeAdapter((o, cancel) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      final controller = StreamController<Uint8List>();
      controller.add(Uint8List.fromList(_range(0, 10)));
      cancel?.then((_) {
        if (!controller.isClosed) {
          controller.addError(DioException(
              requestOptions: o, type: DioExceptionType.cancel));
          controller.close();
        }
      });
      return ResponseBody(controller.stream, 200, headers: {
        'content-length': ['100'],
      });
    });
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    final dir = mkDir('t4');
    engine.submit(_task('t4',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: dir));
    await rec.wait('t4', TaskStatus.running);

    await engine.cancel('t4');
    await rec.wait('t4', TaskStatus.canceled);
    expect(engine.tasks['t4']!.status, TaskStatus.canceled);
    expect(rec.seq['t4']!.contains(TaskStatus.failed), isFalse);

    await rec.dispose();
    await engine.dispose();
  });

  test('5. cold-start recovery: running → loadFromStore 降级为 paused，不自动续传',
      () async {
    final store = MemoryTaskStore();
    final dir = mkDir('t5');
    await store.upsert(_task('t5',
            kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: dir)
        .copyWith(status: TaskStatus.running));

    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    await engine.loadFromStore();
    expect(engine.tasks['t5']!.status, TaskStatus.paused);
    expect((await store.loadAll()).single.status, TaskStatus.paused);

    // 稍等，确认没有被自动拉起（不会出现 running）。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.tasks['t5']!.status, TaskStatus.paused);
    expect(rec.seq['t5']?.contains(TaskStatus.running) ?? false, isFalse);

    await rec.dispose();
    await engine.dispose();
  });

  test('6. concurrency cap=1: 两任务不同时活跃，最终都 completed', () async {
    final gate1 = Completer<void>();
    final gate2 = Completer<void>();
    final adapter = _FakeAdapter((o, c) async {
      final url = o.uri.toString();
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['50'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      final gate = url.contains('a.mp4') ? gate1 : gate2;
      final body = _range(0, 50);
      Stream<Uint8List> gated() async* {
        await gate.future;
        yield Uint8List.fromList(body);
      }

      return ResponseBody(gated(), 200, headers: {
        'content-length': ['50'],
      });
    });
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
      config: const DownloadConfig(maxConcurrency: 1),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('a',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('a')));
    engine.submit(_task('b',
        kind: SourceKind.mp4, url: 'https://cdn/b.mp4', dir: mkDir('b')));

    await rec.wait('a', TaskStatus.running);
    // cap=1：b 仍在排队，未活跃。
    expect(engine.tasks['b']!.status, TaskStatus.queued);
    expect(rec.seq['b']?.contains(TaskStatus.running) ?? false, isFalse);

    gate1.complete();
    await rec.wait('a', TaskStatus.completed);
    // a 完成后 b 才被拉起。
    await rec.wait('b', TaskStatus.running);
    gate2.complete();
    await rec.wait('b', TaskStatus.completed);

    expect(engine.tasks['a']!.status, TaskStatus.completed);
    expect(engine.tasks['b']!.status, TaskStatus.completed);

    await rec.dispose();
    await engine.dispose();
  });

  test('7. failure: 非取消错误 → failed 且 error 有值', () async {
    final adapter = _FakeAdapter((o, c) async => _bytesBody(403, const []));
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t7',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t7')));
    await rec.wait('t7', TaskStatus.failed);

    final t = engine.tasks['t7']!;
    expect(t.status, TaskStatus.failed);
    expect(t.error, isNotNull);
    expect(t.error, isNotEmpty);

    await rec.dispose();
    await engine.dispose();
  });

  // 首个 GET 吐 30 字节后等 token 取消再中断；记录 GET 次数以断言「不重跑」。
  ({_FakeAdapter adapter, int Function() gets}) interruptibleMp4() {
    var gets = 0;
    final adapter = _FakeAdapter((o, cancel) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['100'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      gets++;
      final controller = StreamController<Uint8List>();
      controller.add(Uint8List.fromList(_range(0, 30)));
      cancel?.then((_) {
        if (!controller.isClosed) {
          controller.addError(
              DioException(requestOptions: o, type: DioExceptionType.cancel));
          controller.close();
        }
      });
      return ResponseBody(controller.stream, 200, headers: {
        'content-length': ['100'],
      });
    });
    return (adapter: adapter, gets: () => gets);
  }

  test('8. pause→resume→cancel（finally 窗口内）→ 最终 canceled 且不重跑', () async {
    final io = interruptibleMp4();
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(io.adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t8',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t8')));
    await rec.wait('t8', TaskStatus.running);
    await rec.waitWhere((ev) => ev.taskId == 't8' && ev.downloadedBytes > 0);

    // 三连击落在 worker 异步收尾之前：最后的 cancel 必须压过 resume。
    engine.pause('t8');
    engine.resume('t8');
    await engine.cancel('t8');

    await rec.wait('t8', TaskStatus.canceled);
    // 再等一拍，确认没有被 resume 复活。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.tasks['t8']!.status, TaskStatus.canceled);
    expect(io.gets(), 1, reason: '不应发起第二次 GET（未重跑）');
    // transitions 合并连续重复（进度事件也带 running，用它判断有没有第二轮 running）。
    expect(rec.transitions('t8').where((s) => s == TaskStatus.running).length, 1,
        reason: '只应启动一次');

    await rec.dispose();
    await engine.dispose();
  });

  test('9. pause→resume→pause → 最终 paused 且不重跑', () async {
    final io = interruptibleMp4();
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(io.adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t9',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t9')));
    await rec.wait('t9', TaskStatus.running);
    await rec.waitWhere((ev) => ev.taskId == 't9' && ev.downloadedBytes > 0);

    engine.pause('t9');
    engine.resume('t9');
    engine.pause('t9');

    await rec.wait('t9', TaskStatus.paused);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.tasks['t9']!.status, TaskStatus.paused);
    expect(io.gets(), 1, reason: '不应重跑');
    expect(rec.transitions('t9').where((s) => s == TaskStatus.running).length, 1,
        reason: '只应启动一次');

    await rec.dispose();
    await engine.dispose();
  });

  test('10. remux 期间 cancel → canceled（非 completed），remuxer.cancel 被调',
      () async {
    final gate = Completer<void>();
    final remuxer = _FakeRemuxer(gate: gate);
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _hlsDl(_hlsAdapter()),
      remuxer: remuxer,
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t10',
        kind: SourceKind.hls,
        url: 'https://cdn/hls/index.m3u8',
        dir: mkDir('t10')));
    await rec.wait('t10', TaskStatus.remuxing);

    await engine.cancel('t10');
    await rec.wait('t10', TaskStatus.canceled);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.tasks['t10']!.status, TaskStatus.canceled);
    expect(remuxer.canceled, contains('t10'));
    expect(rec.seq['t10']!.contains(TaskStatus.completed), isFalse);

    await rec.dispose();
    await engine.dispose();
  });

  test('11. remux 期间 pause → paused（非 completed），remuxer.cancel 被调',
      () async {
    final gate = Completer<void>();
    final remuxer = _FakeRemuxer(gate: gate);
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _hlsDl(_hlsAdapter()),
      remuxer: remuxer,
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t11',
        kind: SourceKind.hls,
        url: 'https://cdn/hls/index.m3u8',
        dir: mkDir('t11')));
    await rec.wait('t11', TaskStatus.remuxing);

    engine.pause('t11');
    await rec.wait('t11', TaskStatus.paused);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.tasks['t11']!.status, TaskStatus.paused);
    expect(remuxer.canceled, contains('t11'));
    expect(rec.seq['t11']!.contains(TaskStatus.completed), isFalse);

    await rec.dispose();
    await engine.dispose();
  });

  test('12. remux 失败 → failed 且 error 有值', () async {
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _hlsDl(_hlsAdapter()),
      remuxer: _FakeRemuxer(ok: false),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t12',
        kind: SourceKind.hls,
        url: 'https://cdn/hls/index.m3u8',
        dir: mkDir('t12')));
    await rec.wait('t12', TaskStatus.failed);

    final t = engine.tasks['t12']!;
    expect(t.status, TaskStatus.failed);
    expect(t.error, isNotNull);
    expect(t.error, isNotEmpty);

    await rec.dispose();
    await engine.dispose();
  });

  test('13. cap=2: 两任务真并发（同时 running），最终都 completed', () async {
    final gates = {
      'a.mp4': Completer<void>(),
      'b.mp4': Completer<void>(),
    };
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_gatedMp4Adapter(gates)),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
      config: const DownloadConfig(maxConcurrency: 2),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('a',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('a')));
    engine.submit(_task('b',
        kind: SourceKind.mp4, url: 'https://cdn/b.mp4', dir: mkDir('b')));

    // 两个都进入 running 才放行，证明确实并发。
    await rec.wait('a', TaskStatus.running);
    await rec.wait('b', TaskStatus.running);

    gates['a.mp4']!.complete();
    gates['b.mp4']!.complete();
    await rec.wait('a', TaskStatus.completed);
    await rec.wait('b', TaskStatus.completed);

    expect(engine.tasks['a']!.status, TaskStatus.completed);
    expect(engine.tasks['b']!.status, TaskStatus.completed);

    await rec.dispose();
    await engine.dispose();
  });

  test('14. prioritize: 队首插队，cap=1 下被提前者先跑', () async {
    final gates = {
      'a.mp4': Completer<void>(),
      'b.mp4': Completer<void>(),
      'c.mp4': Completer<void>(),
    };
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_gatedMp4Adapter(gates)),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
      config: const DownloadConfig(maxConcurrency: 1),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('a',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('a')));
    engine.submit(_task('b',
        kind: SourceKind.mp4, url: 'https://cdn/b.mp4', dir: mkDir('b')));
    engine.submit(_task('c',
        kind: SourceKind.mp4, url: 'https://cdn/c.mp4', dir: mkDir('c')));

    await rec.wait('a', TaskStatus.running);
    engine.prioritize('c'); // c 插到 b 前面

    gates['a.mp4']!.complete();
    await rec.wait('c', TaskStatus.running); // a 之后应是 c
    expect(engine.tasks['b']!.status, TaskStatus.queued,
        reason: 'b 应仍在等待，未抢在 c 前');

    gates['c.mp4']!.complete();
    await rec.wait('b', TaskStatus.running);
    gates['b.mp4']!.complete();
    await rec.wait('a', TaskStatus.completed);
    await rec.wait('b', TaskStatus.completed);
    await rec.wait('c', TaskStatus.completed);

    await rec.dispose();
    await engine.dispose();
  });

  test('15. setMaxConcurrency: 从 1 提到 2 后第二个任务被拉起，均不重复启动',
      () async {
    final gates = {
      'a.mp4': Completer<void>(),
      'b.mp4': Completer<void>(),
    };
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_gatedMp4Adapter(gates)),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
      config: const DownloadConfig(maxConcurrency: 1),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('a',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('a')));
    engine.submit(_task('b',
        kind: SourceKind.mp4, url: 'https://cdn/b.mp4', dir: mkDir('b')));

    await rec.wait('a', TaskStatus.running);
    expect(engine.tasks['b']!.status, TaskStatus.queued);

    await engine.setMaxConcurrency(2);
    await rec.wait('b', TaskStatus.running); // 提额后 b 被拉起

    gates['a.mp4']!.complete();
    gates['b.mp4']!.complete();
    await rec.wait('a', TaskStatus.completed);
    await rec.wait('b', TaskStatus.completed);

    expect(rec.transitions('a').where((s) => s == TaskStatus.running).length, 1,
        reason: 'a 只应启动一次');
    expect(rec.transitions('b').where((s) => s == TaskStatus.running).length, 1,
        reason: 'b 只应启动一次');

    await rec.dispose();
    await engine.dispose();
  });

  test('16. remove: 下载中删除 → 任务立刻从 tasks 消失、store 清除、不复活', () async {
    final gates = {'a.mp4': Completer<void>()};
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_gatedMp4Adapter(gates)),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('a',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('a')));
    await rec.wait('a', TaskStatus.running);

    // 下载进行中删除：内存表立刻移除（UI 依此重建列表 → 即刻消失），存储清除。
    await engine.remove('a');
    expect(engine.tasks.containsKey('a'), isFalse);
    expect(await store.loadAll(), isEmpty);

    // 广播了终态事件供 UI 收尾。
    expect(rec.seq['a'], contains(TaskStatus.canceled));

    // 活跃 worker 随后被取消收尾：不得复活任务、不得回写存储。
    gates['a.mp4']!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(engine.tasks.containsKey('a'), isFalse, reason: '收尾后不得复活');
    expect(await store.loadAll(), isEmpty, reason: '收尾后不得回写存储');

    await rec.dispose();
    await engine.dispose();
  });

  test('17. completed 后 pause/cancel 被忽略：状态保持 completed，不被降级', () async {
    final full = _range(0, 50);
    final adapter = _FakeAdapter((o, c) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['50'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      return _bytesBody(200, full, headers: {
        'content-length': ['50'],
      });
    });
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t17',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t17')));
    await rec.wait('t17', TaskStatus.completed);

    engine.pause('t17');
    await engine.cancel('t17');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.tasks['t17']!.status, TaskStatus.completed);
    expect(rec.seq['t17']!.contains(TaskStatus.paused), isFalse,
        reason: 'completed 不得被降级为 paused');
    expect(rec.seq['t17']!.contains(TaskStatus.canceled), isFalse,
        reason: 'completed 不得被降级为 canceled');

    await rec.dispose();
    await engine.dispose();
  });

  test('18. cancel 落在 mp4 下载完成与 completed 提交之间：终态 canceled 不被覆盖',
      () async {
    final full = _range(0, 50);
    final adapter = _FakeAdapter((o, c) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['50'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      return _bytesBody(200, full, headers: {
        'content-length': ['50'],
      });
    });
    final store = MemoryTaskStore();
    late final DownloadEngine engine;
    final dio = Dio()..httpClientAdapter = adapter;
    engine = DownloadEngine(
      store: store,
      mp4Downloader: _HookedMp4Downloader(
        http: HttpClient(const DownloadConfig(), dio: dio),
        refresher: UrlRefresher(backoff: Duration.zero),
        beforeReturn: (id) => unawaited(engine.cancel(id, deleteFiles: true)),
      ),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t18',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t18')));
    await rec.wait('t18', TaskStatus.canceled);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.tasks['t18']!.status, TaskStatus.canceled);
    expect(rec.seq['t18']!.contains(TaskStatus.completed), isFalse,
        reason: '取消已落定，completed 不得覆盖（否则文件已删仍标完成）');

    await rec.dispose();
    await engine.dispose();
  });

  test('19. cancel 落在 hls 下载完成与 remuxing 提交之间：不进 remuxing，终态 canceled',
      () async {
    final store = MemoryTaskStore();
    late final DownloadEngine engine;
    final dio = Dio()..httpClientAdapter = _hlsAdapter();
    engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _HookedHlsDownloader(
        http: HttpClient(const DownloadConfig(), dio: dio),
        refresher: UrlRefresher(backoff: Duration.zero),
        beforeReturn: (id) => unawaited(engine.cancel(id)),
      ),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t19',
        kind: SourceKind.hls,
        url: 'https://cdn/hls/index.m3u8',
        dir: mkDir('t19')));
    await rec.wait('t19', TaskStatus.canceled);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(engine.tasks['t19']!.status, TaskStatus.canceled);
    expect(rec.seq['t19']!.contains(TaskStatus.remuxing), isFalse,
        reason: '取消已落定，不得再进 remuxing（否则永远卡在 remuxing）');
    expect(rec.seq['t19']!.contains(TaskStatus.completed), isFalse);

    await rec.dispose();
    await engine.dispose();
  });

  test('20. mp4 中途暂停：HEAD 返回的 etag 已持久化到任务（含 JSON 往返）', () async {
    final io = interruptibleMp4();
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(io.adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t20',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t20')));
    await rec.wait('t20', TaskStatus.running);
    await rec.waitWhere((ev) => ev.taskId == 't20' && ev.downloadedBytes > 0);

    engine.pause('t20');
    await rec.wait('t20', TaskStatus.paused);

    // HEAD 一返回 etag 就该持久化：中途暂停/被杀后仍能防内容变更。
    final stored =
        (await store.loadAll()).firstWhere((e) => e.taskId == 't20');
    expect(stored.etag, '"v1"');
    expect(DownloadTask.fromJson(stored.toJson()).etag, '"v1"',
        reason: 'etag 必须进 JSON 持久化往返');

    await rec.dispose();
    await engine.dispose();
  });

  test('21. mp4 误判自动纠正：URL 内容是 HLS → 任务改 kind=hls 同轮完成', () async {
    final adapter = _FakeAdapter((o, c) async {
      final url = o.uri.toString();
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['${_hlsPlaylist.length}'],
          'accept-ranges': ['bytes'],
        });
      }
      // 同一 URL 既被 mp4 下载器 GET（嗅探出 m3u8），也被 HLS 下载器当入口解析。
      if (url == 'https://cdn/video') {
        return _bytesBody(200, _hlsPlaylist.codeUnits);
      }
      if (url.endsWith('/seg0.ts')) return _bytesBody(200, _range(0, 10));
      if (url.endsWith('/seg1.ts')) return _bytesBody(200, _range(10, 20));
      if (url.endsWith('/seg2.ts')) return _bytesBody(200, _range(20, 30));
      return _bytesBody(404, const []);
    });
    final store = MemoryTaskStore();
    final dio = Dio()..httpClientAdapter = adapter;
    final http = HttpClient(const DownloadConfig(), dio: dio);
    final refresher = UrlRefresher(backoff: Duration.zero);
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: Mp4Downloader(http: http, refresher: refresher),
      hlsDownloader: HlsDownloader(http: http, refresher: refresher),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    final dir = mkDir('t21');
    engine.submit(_task('t21',
        kind: SourceKind.mp4, url: 'https://cdn/video', dir: dir));
    await rec.waitWhere((ev) =>
        ev.taskId == 't21' &&
        (ev.status == TaskStatus.completed || ev.status == TaskStatus.failed));

    final t = engine.tasks['t21']!;
    expect(t.status, TaskStatus.completed);
    expect(t.kind, SourceKind.hls, reason: '误判应被纠正为 hls，而非永久失败');
    expect(t.mp4Path, '$dir/video.mp4');
    expect(File(t.mp4Path!).existsSync(), isTrue);
    expect(rec.seq['t21'], contains(TaskStatus.remuxing));

    final stored =
        (await store.loadAll()).firstWhere((e) => e.taskId == 't21');
    expect(stored.kind, SourceKind.hls, reason: '纠正后的 kind 必须持久化');

    await rec.dispose();
    await engine.dispose();
  });

  test('22. 进度节流：200 个快速分块折叠为少量事件，单调且终值正确', () async {
    const chunkCount = 200;
    const chunkSize = 1024;
    const total = chunkCount * chunkSize;
    final adapter = _FakeAdapter((o, c) async {
      if (o.method == 'HEAD') {
        return _bytesBody(200, const [], headers: {
          'content-length': ['$total'],
          'etag': ['"v1"'],
          'accept-ranges': ['bytes'],
        });
      }
      Stream<Uint8List> chunks() async* {
        for (var i = 0; i < chunkCount; i++) {
          yield Uint8List.fromList(List.filled(chunkSize, i & 0xff));
        }
      }

      return ResponseBody(chunks(), 200, headers: {
        'content-length': ['$total'],
      });
    });
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(adapter),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t22',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('t22')));
    await rec.wait('t22', TaskStatus.completed);

    // running 且 downloadedBytes>0 的事件 = 放行的进度提交。
    // 200 个分块背靠背到达，每多放行一个事件需要 ≥100ms 间隔：出现 20 个
    // 事件意味着内存流花了 ≥1.9s，不可能——上界宽松而确定，不依赖具体时序。
    final progressEvents = rec.events
        .where((e) =>
            e.taskId == 't22' &&
            e.status == TaskStatus.running &&
            e.downloadedBytes > 0)
        .toList();
    expect(progressEvents, isNotEmpty);
    expect(progressEvents.length, lessThanOrEqualTo(20),
        reason: '200 个分块的进度应被节流折叠');
    for (var i = 1; i < progressEvents.length; i++) {
      expect(progressEvents[i].downloadedBytes,
          greaterThanOrEqualTo(progressEvents[i - 1].downloadedBytes),
          reason: '进度应单调不减');
    }
    // 终态回填不受节流影响：完成时字节即 mp4 实际大小。
    final t = engine.tasks['t22']!;
    expect(t.downloadedBytes, total);
    expect(t.totalBytes, total);
    expect(File(t.mp4Path!).lengthSync(), total);

    await rec.dispose();
    await engine.dispose();
  });

  test('23. remuxing 进度：totalBytes=分片总输入字节，期间有递增进度，完成回填 mp4 字节',
      () async {
    final remuxer = _FakeRemuxer(reportProgress: true);
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_idleAdapter()),
      hlsDownloader: _hlsDl(_hlsAdapter()),
      remuxer: remuxer,
    );
    final rec = _Recorder(engine);

    engine.submit(_task('t23',
        kind: SourceKind.hls,
        url: 'https://cdn/hls/index.m3u8',
        dir: mkDir('t23')));
    await rec.wait('t23', TaskStatus.completed);

    // 3 片 × 10 字节：进 remuxing 时 totalBytes 应为分片总输入字节 30。
    final remuxEvents = rec.events
        .where((e) => e.taskId == 't23' && e.status == TaskStatus.remuxing)
        .toList();
    expect(remuxEvents, isNotEmpty);
    expect(remuxEvents.every((e) => e.totalBytes == 30), isTrue,
        reason: 'remuxing 期间 totalBytes 应为分片总输入字节');
    expect(remuxEvents.first.downloadedBytes, 0,
        reason: '进入 remuxing 的状态提交应从 0 开始');
    // 换阶段重开节流窗口：remux 的首笔进度必然放行。
    expect(remuxEvents.any((e) => e.downloadedBytes == 15), isTrue,
        reason: 'remux 期间应观察到真实进度');

    // 完成回填：终态 downloadedBytes == totalBytes == mp4 文件大小。
    final t = engine.tasks['t23']!;
    expect(t.status, TaskStatus.completed);
    expect(File(t.mp4Path!).lengthSync(), 4);
    expect(t.downloadedBytes, 4);
    expect(t.totalBytes, 4);

    await rec.dispose();
    await engine.dispose();
  });

  test('24. pause 排队中任务：意图不残留，resume 后正常跑到 completed', () async {
    final gates = {
      'a.mp4': Completer<void>(),
      'b.mp4': Completer<void>(),
    };
    final store = MemoryTaskStore();
    final engine = DownloadEngine(
      store: store,
      mp4Downloader: _mp4Dl(_gatedMp4Adapter(gates)),
      hlsDownloader: _hlsDl(_idleAdapter()),
      remuxer: _FakeRemuxer(),
      config: const DownloadConfig(maxConcurrency: 1),
    );
    final rec = _Recorder(engine);

    engine.submit(_task('a',
        kind: SourceKind.mp4, url: 'https://cdn/a.mp4', dir: mkDir('a')));
    engine.submit(_task('b',
        kind: SourceKind.mp4, url: 'https://cdn/b.mp4', dir: mkDir('b')));
    await rec.wait('a', TaskStatus.running);
    expect(engine.tasks['b']!.status, TaskStatus.queued);

    // 暂停仅排队（非活跃）的 b：没有 worker 收尾兜底，意图必须就地清理。
    engine.pause('b');
    await rec.wait('b', TaskStatus.paused);

    gates['a.mp4']!.complete();
    await rec.wait('a', TaskStatus.completed);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // a 完成不得拉起已暂停的 b；a 的 worker 已收尾、b 从未活跃 → 意图表应为空。
    expect(engine.tasks['b']!.status, TaskStatus.paused);
    expect(engine.pendingIntentCount, 0,
        reason: '非活跃任务的 pause 意图不得残留');

    // 残留清理不得影响后续 resume：b 正常跑到 completed。
    engine.resume('b');
    gates['b.mp4']!.complete();
    await rec.wait('b', TaskStatus.completed);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.tasks['b']!.status, TaskStatus.completed);
    expect(engine.pendingIntentCount, 0);

    await rec.dispose();
    await engine.dispose();
  });
}
