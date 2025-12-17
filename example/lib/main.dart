import 'dart:io';

import 'package:ffmpeg_remux/download/download_library.dart';
import 'package:flutter/material.dart';
import 'dart:async';


void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final StreamSubscription sub;
  final _urlController = TextEditingController(
    // text: 'https://sf1-cdn-tos.huoshanstatic.com/obj/media-fe/xgplayer_doc_video/mp4/xgplayer-demo-360p.mp4',
    text: '你的m3u8',
  );
  final _mgr = DownloadManager.instance;
  StreamSubscription? _sub;
  String local = "";
  String dir = "";
  double progress = 0.0;
  bool _isDownloading = false;


  double _calcProgress(M3u8Task t) {
    if (t.kind == SourceKind.hls) {
      final total = t.effectiveTotal;
      if (total <= 0) return 0;
      return (t.completed / total).clamp(0.0, 1.0);
    } else {
      final total = t.contentLength ?? 0;
      if (total <= 0) return 0;
      return (t.downloaded / total).clamp(0.0, 1.0);
    }
  }

  @override
  void initState() {
    super.initState();
    _mgr.ensureInitialized();
    _sub = _mgr.taskStream.listen((t) {
      setState(() {
        progress = _calcProgress(t);
      });
      final percent = t.effectiveTotal == 0
          ? 0
          : (t.completed * 100 ~/ t.effectiveTotal);
      print('下载进度:$percent}');
      if (t.status == TaskStatus.completed) {
        setState(() {
          local = '${t.dir}/local.m3u8';
          dir = t.dir;
          print("m3u8地址或者mp4地址:${t.mp4Path}==${t.localPath}");
        });
      }
    });
  }

  Future<void> _downloadAndSave() async {
    // final url = _urlController.text.trim();
    // if (url.isEmpty) return;
    //
    // setState(() {
    //   _isDownloading = true;
    //   progress = 0.0;
    // });
    //
    // try {
    //   final tempDir = await getTemporaryDirectory();
    //   final fileName = 'video_${DateTime.now().millisecondsSinceEpoch}.mp4';
    //   final savePath = '${tempDir.path}/$fileName';
    //
    //   final dio = Dio();
    //   await dio.download(
    //     url,
    //     savePath,
    //     onReceiveProgress: (received, total) {
    //       if (total > 0) {
    //         setState(() {
    //           progress = (received / total) * 0.9;
    //         });
    //       }
    //     },
    //   );
    //
    //   final result = await SaverGallery.saveFile(
    //     filePath: savePath,
    //     fileName: fileName,
    //     androidRelativePath: 'Movies',
    //     skipIfExists: false,
    //   );
    //
    //   if (result.isSuccess) {
    //     setState(() {
    //       progress = 1.0;
    //     });
    //     if (mounted) {
    //       ScaffoldMessenger.of(context).showSnackBar(
    //         const SnackBar(content: Text('保存到相册成功')),
    //       );
    //     }
    //   } else {
    //     if (mounted) {
    //       ScaffoldMessenger.of(context).showSnackBar(
    //         const SnackBar(content: Text('保存到相册失败')),
    //       );
    //     }
    //   }
    //
    //   try {
    //     await File(savePath).delete();
    //   } catch (_) {}
    // } catch (e) {
    //   print('下载失败: $e');
    //   if (mounted) {
    //     ScaffoldMessenger.of(context).showSnackBar(
    //       SnackBar(content: Text('下载失败: $e')),
    //     );
    //   }
    // } finally {
    //   setState(() {
    //     _isDownloading = false;
    //   });
    // }
  }


  @override
  void dispose() {
    sub.cancel();
    _sub?.cancel();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('movie_download')),
      body: Center(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  hintText: '请输入视频链接',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _isDownloading ? null : _downloadAndSave,
              child: Text(_isDownloading ? '下载中...' : '下载并保存到相册'),
            ),
            const SizedBox(height: 16),

            ElevatedButton(
              onPressed: () async {
                final url = _urlController.text.trim();
                DownloadManager.instance.addOrResumeFormMeta(
                  taskId: "9528",
                  movieId: url,
                  lid: url,
                  name: "骚货",
                  coverImg: url,
                  url: url,
                );
              },
              child: Text('下载', style: TextStyle(color: Colors.black)),
            ),
            Text(local),
            LinearProgressIndicator(value: progress),
          ],
        ),
      ),
    );
  }
}
