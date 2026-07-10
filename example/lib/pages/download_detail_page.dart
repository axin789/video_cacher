import 'package:video_cacher/video_cacher.dart';
import 'package:flutter/material.dart';

import 'download_list_page.dart';

class DownloadDetailPage extends StatefulWidget {
  const DownloadDetailPage({super.key});

  @override
  State<DownloadDetailPage> createState() => _DownloadDetailPageState();
}

class _DownloadDetailPageState extends State<DownloadDetailPage> {
  final _mgr = VideoCacher.instance;
  final _urlController = TextEditingController();
  final _idController = TextEditingController();
  final _nameController = TextEditingController();
  final _coverController = TextEditingController();
  bool _saveToAlbum = false;
  bool _submitting = false;
  String _resultText = '请填写下载参数';

  @override
  void dispose() {
    _urlController.dispose();
    _idController.dispose();
    _nameController.dispose();
    _coverController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final id = _idController.text.trim();
    final name = _nameController.text.trim();
    final cover = _coverController.text.trim();
    final url = _urlController.text.trim();
    if (id.isEmpty || name.isEmpty || url.isEmpty) {
      setState(() => _resultText = 'id / name / url 不能为空');
      return;
    }

    setState(() {
      _submitting = true;
      _resultText = '正在创建下载任务...';
    });

    try {
      final existing = _mgr.tasks[id];
      if (existing != null) {
        if (existing.status == TaskStatus.completed) {
          if (!mounted) return;
          setState(() {
            _submitting = false;
            _resultText = '该 id 已下载成功，已在下载列表中';
          });
          return;
        }

        if (existing.status != TaskStatus.failed) {
          if (!mounted) return;
          setState(() {
            _submitting = false;
            _resultText = '该 id 已在下载列表中';
          });
          return;
        }

        // TODO(phase1): 新 API 没有「带新 url 重试」的入口，这里用 删除+重新入队
        // 等价实现，以便沿用用户新填的 url（会丢弃失败任务的断点分片，从头开始）。
        await _mgr.deleteTask(id);
        final task = await _mgr.enqueue(
          id: id,
          name: name,
          cover: cover.isEmpty ? 'https://picsum.photos/300/420' : cover,
          url: url,
          saveToAlbum: _saveToAlbum,
        );
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _resultText = '失败任务已更新下载地址并重新开始: ${task.taskId}';
        });
        return;
      }

      final task = await _mgr.enqueue(
        id: id,
        name: name,
        cover: cover.isEmpty ? 'https://picsum.photos/300/420' : cover,
        url: url,
        saveToAlbum: _saveToAlbum,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _resultText = '任务已加入队列: ${task.taskId}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _resultText = '提交失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('下载详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _idController,
            decoration: const InputDecoration(
              labelText: '视频 id',
              hintText: '请输入唯一的视频 id',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: '视频名称',
              hintText: '请输入展示用的视频名称',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _coverController,
            decoration: const InputDecoration(
              labelText: '封面地址',
              hintText: '请输入封面图片 URL，可选',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: '下载地址',
              hintText: '请输入 mp4 或 m3u8 地址',
            ),
            maxLines: 4,
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            value: _saveToAlbum,
            onChanged: (value) => setState(() => _saveToAlbum = value),
            contentPadding: EdgeInsets.zero,
            title: const Text('下载完成后复制到相册'),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(_submitting ? '提交中...' : '开始/恢复'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const DownloadListPage()),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              side: const BorderSide(color: Color(0xFF5A7DFF)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text('查看下载列表'),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF101010),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0xFF262626)),
            ),
            child: Text(
              _resultText,
              style: const TextStyle(fontSize: 15, color: Color(0xFFE5E5E5)),
            ),
          ),
        ],
      ),
    );
  }
}
