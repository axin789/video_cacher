/// remux 结果。
class RemuxResult {
  final bool ok;
  final String? outMp4;
  final String? error;
  const RemuxResult({required this.ok, this.outMp4, this.error});
}

/// 把有序的已解密 TS 分片合成为 mp4 的抽象。
///
/// 当前唯一实现为纯 Dart transmuxer；未来 h265 实现同样遵循此接口。
abstract class Remuxer {
  /// 把按播放列表顺序排好的已解密分片 [segmentFiles] 合成到 [outMp4]。
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles, // 绝对路径，播放列表顺序
    required String outMp4, // 绝对输出路径
    required String dir, // 任务工作目录（写临时 local.m3u8 用）
    void Function(int bytes)? onProgress, // 已输出字节数（尽力而为）
  });

  /// 尽力取消 [taskId] 正在进行的 remux。
  void cancel(String taskId);

  /// 成功后清理中间产物（ts/tmp/local.m3u8），保留 mp4。
  Future<void> cleanup({
    required String dir,
    required String? outMp4,
    required bool success,
  });
}
