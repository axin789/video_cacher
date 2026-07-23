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
  ///
  /// [onProgress] 回报「已喂入的累计输入字节数」（每消费完一个分片回调一次，
  /// 单调递增，最大为分片总字节）；与总输入字节相除即得 0..1 进度。
  Future<RemuxResult> remux({
    required String taskId,
    required List<String> segmentFiles, // 绝对路径，播放列表顺序
    required String outMp4, // 绝对输出路径
    required String dir, // 任务工作目录（写临时 local.m3u8 用）
    void Function(int bytes)? onProgress, // 已喂入累计输入字节
  });

  /// 取消 [taskId] 正在进行的 remux（实现可强杀 worker 并清理中间产物）。
  void cancel(String taskId);

  /// 成功后清理中间产物（ts/tmp/local.m3u8），保留 mp4。
  Future<void> cleanup({
    required String dir,
    required String? outMp4,
    required bool success,
  });
}
