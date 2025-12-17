import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';


/// 全局唯一的本地HTTP服务，用于让 iOS 播放本地m3u8/ts
class LocalVideoServer {
  static final LocalVideoServer _instance = LocalVideoServer._internal();
  factory LocalVideoServer() => _instance;
  LocalVideoServer._internal();

  HttpServer? _server;
  static const int _preferPort = 18080; // 固定端口，避免端口变化问题
  int? _port;                           // 实际使用的端口
  int get port => _port ?? _preferPort;
  bool get isRunning => _server != null;


  /// 启动服务，只启动一次
  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, _preferPort);
      _port = _server!.port;
    }on SocketException catch (e) {
      // 2. 如果是端口被占用，改用随机端口
      final code = e.osError?.errorCode;
      if (code == 48 || code == 98) {
        // 让系统分配一个空闲端口
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        _port = _server!.port;
      } else {
        rethrow; // 其他错误还是抛出去
      }
    } catch (e) {
      print(' 服务启动错误: $e');
      rethrow;
    }
    _server!.defaultResponseHeaders.chunkedTransferEncoding = false;
    print(' 服务启动: http://127.0.0.1:$port');
    _server!.listen(_handleRequest, onError: (e) {
      print(' 服务报错: $e');
    });
  }

  /// 确保服务运行
  Future<void> ensureRunning() async {
    if (_server == null) {
      await start();
    }
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      final root = await getApplicationSupportDirectory();
      final rootPath = root.path;
      final rel = Uri.decodeFull(req.uri.path);
      final relNoSlash = rel.startsWith('/') ? rel.substring(1) : rel;
      final abs = p.normalize(p.join(rootPath, relNoSlash));
      final file = File(abs);

      if (!await file.exists()) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }

      final ext = p.extension(abs).toLowerCase();
      final mime = switch (ext) {
        '.m3u8' => 'application/vnd.apple.mpegurl; charset=utf-8',
        '.ts'   => 'video/MP2T',
        '.mp4'  => 'video/mp4',
        _       => 'application/octet-stream',
      };

      final total = await file.length();
      final h = req.response.headers
        ..set(HttpHeaders.contentTypeHeader, mime)
        ..set(HttpHeaders.acceptRangesHeader, 'bytes');

      if (req.method == 'HEAD') {
        h.contentLength = total;
        req.response.statusCode = HttpStatus.ok;
        await req.response.close();
        return;
      }

      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null && range.startsWith('bytes=')) {
        final parts = range.substring(6).split('-');
        int start = int.tryParse(parts[0]) ?? 0;
        int end   = int.tryParse(parts.length > 1 ? parts[1] : '') ?? (total - 1);
        if (end >= total) end = total - 1;
        if (start < 0 || start > end) {
          req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await req.response.close();
          return;
        }
        final len = end - start + 1;
        req.response.statusCode = HttpStatus.partialContent;
        h
          ..set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total')
          ..contentLength = len;

        await req.response.addStream(File(abs).openRead(start, end + 1));
        await req.response.close();
        return;
      }

      h.contentLength = total; // 明确长度，避免 chunked
      req.response.statusCode = HttpStatus.ok;
      await req.response.addStream(File(abs).openRead());
      await req.response.close();
    } catch (_) {
      try { req.response.statusCode = HttpStatus.internalServerError; await req.response.close(); } catch (_) {}
    }
  }

  /// 拼接成完整访问 URL（注意：path 要传**绝对路径**）
  String urlForFile(String absPath) => 'http://127.0.0.1:$port${Uri.encodeFull(absPath)}';

  Future<String> urlForAbsPath(String absPath) async {
    final root = await getApplicationSupportDirectory(); // ✅ 改这里
    final rootPath = p.normalize(root.path);
    final ap = p.normalize(absPath);

    if (!p.isWithin(rootPath, ap) && ap != rootPath) {
      throw StateError('absPath not under ApplicationSupportDirectory: $ap');
    }

    final rel = p.relative(ap, from: rootPath).replaceAll('\\', '/');
    final safePath = Uri(path: '/$rel').toString(); // 自动编码中文/空格
    return 'http://127.0.0.1:$port$safePath';
  }

  Future<String> urlForLocalM3u8(String localM3u8AbsPath) async {
    // return urlForFile('/m3u8_task/${t.taskId}/local.m3u8');
    print("呵呵哒$localM3u8AbsPath");
    return urlForAbsPath(localM3u8AbsPath);
  }
}
