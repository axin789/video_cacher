import 'dart:async';

import 'package:video_cacher/video_cacher.dart';
import 'package:flutter/material.dart';

import '../widgets/mini_action_button.dart';
import 'video_player_page.dart';

class DownloadListPage extends StatefulWidget {
  const DownloadListPage({super.key});

  @override
  State<DownloadListPage> createState() => _DownloadListPageState();
}

class _DownloadListPageState extends State<DownloadListPage> {
  final _mgr = VideoCacher.instance;
  StreamSubscription<TaskEvent>? _sub;
  List<DownloadTask> _tasks = const [];

  @override
  void initState() {
    super.initState();
    _reloadTasks();
    _sub = _mgr.taskStream.listen((_) {
      if (mounted) {
        setState(_reloadTasks);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _reloadTasks() {
    final tasks = _mgr.tasks.values.toList()
      ..sort((a, b) {
        final statusCompare = _weightOfStatus(a.status).compareTo(
          _weightOfStatus(b.status),
        );
        if (statusCompare != 0) return statusCompare;
        return a.taskId.compareTo(b.taskId);
      });
    _tasks = tasks;
  }

  int _weightOfStatus(TaskStatus status) {
    switch (status) {
      case TaskStatus.completed:
        return 0;
      case TaskStatus.running:
      case TaskStatus.queued:
      case TaskStatus.remuxing:
        return 1;
      case TaskStatus.paused:
        return 2;
      case TaskStatus.failed:
        return 3;
      case TaskStatus.canceled:
        return 4;
    }
  }

  String _subtitleOf(DownloadTask task) {
    if (task.error?.isNotEmpty == true) return task.error!;
    if (task.albumError?.isNotEmpty == true) return task.albumError!;
    switch (task.status) {
      case TaskStatus.completed:
        return '下载成功';
      case TaskStatus.running:
        return '下载中';
      case TaskStatus.queued:
        return '等待中';
      case TaskStatus.paused:
        return '已暂停';
      case TaskStatus.failed:
        return '下载失败';
      case TaskStatus.canceled:
        return '已取消';
      case TaskStatus.remuxing:
        return '处理中';
    }
  }

  String _metaOf(DownloadTask task) {
    // HLS 下载中：totalBytes 是分片总数、downloadedBytes 是已完成分片数。
    if (task.kind == SourceKind.hls) {
      return '分片 ${task.downloadedBytes}/${task.totalBytes}';
    }
    final total = task.totalBytes;
    if (total <= 0) return '已下载 ${task.downloadedBytes} B';
    return '${_bytes(task.downloadedBytes)} / ${_bytes(total)}';
  }

  String _bytes(int value) {
    if (value < 1024) return '$value B';
    if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
    if (value < 1024 * 1024 * 1024) {
      return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  double _progressOf(DownloadTask task) => task.progress.toDouble();

  Future<void> _resumeTask(DownloadTask task) async {
    // resume 同时覆盖 paused/failed/queued，失败任务也走它重试。
    _mgr.resume(task.taskId);
    if (mounted) setState(_reloadTasks);
  }

  Future<void> _deleteTask(DownloadTask task) async {
    await _mgr.deleteTask(task.taskId);
    if (mounted) setState(_reloadTasks);
  }

  Future<void> _copyToAlbum(DownloadTask task) async {
    final result = await _mgr.copyToAlbum(task.taskId);
    if (!mounted) return;
    setState(_reloadTasks);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok ? '复制到相册成功' : '复制到相册失败: ${result.error ?? 'unknown'}',
        ),
      ),
    );
  }

  void _showTaskDetail(DownloadTask task) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111111),
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.name, style: const TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                Text('taskId: ${task.taskId}'),
                Text('status: ${task.status.name}'),
                Text('mp4: ${task.mp4Path ?? '-'}', maxLines: 3),
                Text('albumError: ${task.albumError ?? '-'}', maxLines: 3),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openTask(DownloadTask task) {
    final path = task.mp4Path ?? '';
    if (path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前任务还没有可播放文件')),
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          title: task.name,
          filePath: path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final completed =
        _tasks.where((task) => task.status == TaskStatus.completed).toList();
    final processing =
        _tasks.where((task) => task.status != TaskStatus.completed).toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('离线缓存'),
          centerTitle: true,
          bottom: const TabBar(
            indicatorColor: Color(0xFF5A7DFF),
            indicatorWeight: 4,
            labelColor: Colors.white,
            unselectedLabelColor: Color(0xFF8F8F8F),
            tabs: [
              Tab(text: '已完成'),
              Tab(text: '进行中'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            TaskListView(
              tasks: completed,
              subtitleOf: _subtitleOf,
              metaOf: _metaOf,
              progressOf: _progressOf,
              onPause: (task) => setState(() => _mgr.pause(task.taskId)),
              onResume: _resumeTask,
              onDelete: _deleteTask,
              onCopyToAlbum: _copyToAlbum,
              onOpen: (task) => (task.mp4Path?.isNotEmpty ?? false)
                  ? _openTask(task)
                  : _showTaskDetail(task),
            ),
            TaskListView(
              tasks: processing,
              subtitleOf: _subtitleOf,
              metaOf: _metaOf,
              progressOf: _progressOf,
              onPause: (task) => setState(() => _mgr.pause(task.taskId)),
              onResume: _resumeTask,
              onDelete: _deleteTask,
              onCopyToAlbum: _copyToAlbum,
              onOpen: (task) => (task.mp4Path?.isNotEmpty ?? false)
                  ? _openTask(task)
                  : _showTaskDetail(task),
            ),
          ],
        ),
      ),
    );
  }
}

class TaskListView extends StatelessWidget {
  const TaskListView({
    super.key,
    required this.tasks,
    required this.subtitleOf,
    required this.metaOf,
    required this.progressOf,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
    required this.onCopyToAlbum,
    required this.onOpen,
  });

  final List<DownloadTask> tasks;
  final String Function(DownloadTask task) subtitleOf;
  final String Function(DownloadTask task) metaOf;
  final double Function(DownloadTask task) progressOf;
  final void Function(DownloadTask task) onPause;
  final Future<void> Function(DownloadTask task) onResume;
  final Future<void> Function(DownloadTask task) onDelete;
  final Future<void> Function(DownloadTask task) onCopyToAlbum;
  final void Function(DownloadTask task) onOpen;

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return const Center(
        child: Text(
          '暂无任务',
          style: TextStyle(color: Color(0xFF8F8F8F), fontSize: 16),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 24),
      itemBuilder: (context, index) {
        final task = tasks[index];
        return TaskCard(
          task: task,
          subtitle: subtitleOf(task),
          meta: metaOf(task),
          progress: progressOf(task),
          onPause: () => onPause(task),
          onResume: () => onResume(task),
          onDelete: () => onDelete(task),
          onCopyToAlbum: () => onCopyToAlbum(task),
          onOpen: () => onOpen(task),
        );
      },
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemCount: tasks.length,
    );
  }
}

class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.subtitle,
    required this.meta,
    required this.progress,
    required this.onPause,
    required this.onResume,
    required this.onDelete,
    required this.onCopyToAlbum,
    required this.onOpen,
  });

  final DownloadTask task;
  final String subtitle;
  final String meta;
  final double progress;
  final VoidCallback onPause;
  final Future<void> Function() onResume;
  final Future<void> Function() onDelete;
  final Future<void> Function() onCopyToAlbum;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final isCompleted = task.status == TaskStatus.completed;
    final isFailed = task.status == TaskStatus.failed;
    final isPaused = task.status == TaskStatus.paused;
    final isDownloading = task.status == TaskStatus.running ||
        task.status == TaskStatus.queued ||
        task.status == TaskStatus.remuxing;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 116,
            height: 156,
            child: task.coverImg.isEmpty
                ? Container(color: const Color(0xFF1B1B1B))
                : Image.network(
                    task.coverImg,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      color: const Color(0xFF1B1B1B),
                      alignment: Alignment.center,
                      child: const Icon(Icons.image_not_supported_outlined),
                    ),
                  ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                meta,
                style: const TextStyle(fontSize: 14, color: Color(0xFFCFCFCF)),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Color(0xFF9C9C9C)),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final List<Widget> actionChildren = [];
                  if (isCompleted) {
                    actionChildren.add(
                      MiniActionButton(
                        label: '相册',
                        onTap: () => onCopyToAlbum(),
                      ),
                    );
                    actionChildren.add(
                      MiniActionButton(
                        label: '删除',
                        onTap: () => onDelete(),
                      ),
                    );
                  } else if (isFailed) {
                    actionChildren.add(
                      MiniActionButton(
                        label: '重试',
                        onTap: () => onResume(),
                      ),
                    );
                    actionChildren.add(
                      MiniActionButton(
                        label: '删除',
                        onTap: () => onDelete(),
                      ),
                    );
                  } else if (isPaused) {
                    actionChildren.add(
                      MiniActionButton(
                        label: '继续',
                        onTap: () => onResume(),
                      ),
                    );
                    actionChildren.add(
                      MiniActionButton(
                        label: '删除',
                        onTap: () => onDelete(),
                      ),
                    );
                  } else if (isDownloading) {
                    actionChildren.add(
                      MiniActionButton(
                        label: '暂停',
                        onTap: onPause,
                      ),
                    );
                    actionChildren.add(
                      MiniActionButton(
                        label: '删除',
                        onTap: () => onDelete(),
                      ),
                    );
                  } else {
                    actionChildren.add(
                      MiniActionButton(
                        label: '删除',
                        onTap: () => onDelete(),
                      ),
                    );
                  }

                  final actionButtons = Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: actionChildren,
                  );
                  final mainButton = OutlinedButton(
                    onPressed: onOpen,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF5A7DFF),
                      side: const BorderSide(color: Color(0xFF5A7DFF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      minimumSize: const Size(82, 42),
                    ),
                    child: Text(
                      isCompleted && (task.mp4Path?.isNotEmpty ?? false)
                          ? '播放'
                          : '详情',
                    ),
                  );

                  if (constraints.maxWidth < 250) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        actionButtons,
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerRight,
                          child: mainButton,
                        ),
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: actionButtons),
                      const SizedBox(width: 10),
                      mainButton,
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: const Color(0xFF262626),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF5A7DFF)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
