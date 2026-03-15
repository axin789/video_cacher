import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    super.key,
    required this.title,
    required this.filePath,
  });

  final String title;
  final String filePath;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final file = File(widget.filePath);
      if (!await file.exists()) {
        setState(() => _errorText = '文件不存在: ${widget.filePath}');
        return;
      }

      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorText = '播放失败: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Center(
        child: _errorText != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _errorText!,
                  style: const TextStyle(fontSize: 16),
                ),
              )
            : controller == null
                ? const CircularProgressIndicator()
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: controller.value.aspectRatio,
                        child: VideoPlayer(controller),
                      ),
                      const SizedBox(height: 20),
                      IconButton.filled(
                        onPressed: () async {
                          if (controller.value.isPlaying) {
                            await controller.pause();
                          } else {
                            await controller.play();
                          }
                          if (mounted) setState(() {});
                        },
                        icon: Icon(
                          controller.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
