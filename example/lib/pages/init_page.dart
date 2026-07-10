import 'package:video_cacher/video_cacher.dart';
import 'package:flutter/material.dart';

import '../widgets/entry_button.dart';
import 'download_detail_page.dart';
import 'download_list_page.dart';

class InitPage extends StatefulWidget {
  const InitPage({super.key});

  @override
  State<InitPage> createState() => _InitPageState();
}

class _InitPageState extends State<InitPage> {
  final _mgr = VideoCacher.instance;
  late final Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = _initialize();
  }

  Future<void> _initialize() async {
    _mgr.setRefreshUrl((id) async {
      // 这里接入你自己的业务接口：
      // 1. 根据 taskId 查询最新可下载地址
      // 2. 返回最新的 mp4 或 m3u8 播放地址
      // 3. 如果拿不到，返回空字符串
      return '';
    });
    await _mgr.ensureInitialized();
    await _mgr.setMaxConcurrency(3);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        final done = snapshot.connectionState == ConnectionState.done;
        final error = snapshot.error;

        return Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101010),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF262626)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'video_cacher example',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        error == null
                            ? (done ? '下载器已初始化' : '正在初始化下载器...')
                            : '初始化失败: $error',
                        style: const TextStyle(
                          fontSize: 15,
                          color: Color(0xFFB7B7B7),
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (!done && error == null)
                        const Center(child: CircularProgressIndicator())
                      else
                        Column(
                          children: [
                            EntryButton(
                              title: '进入详情',
                              subtitle: '输入参数并开始下载',
                              onTap: error != null
                                  ? null
                                  : () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const DownloadDetailPage(),
                                        ),
                                      ),
                            ),
                            const SizedBox(height: 12),
                            EntryButton(
                              title: '下载列表',
                              subtitle: '查看已完成和进行中的任务',
                              onTap: error != null
                                  ? null
                                  : () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              const DownloadListPage(),
                                        ),
                                      ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
