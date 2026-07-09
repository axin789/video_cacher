import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

/// 相册保存结果：结构化返回成功与否 + 失败原因，绝不抛异常。
class AlbumSaveResult {
  final bool ok;
  final String? error;
  const AlbumSaveResult(this.ok, [this.error]);
}

/// 把本地视频文件保存到系统相册的薄封装。
///
/// 防御式：权限被拒 / 文件缺失 / 底层异常一律映射为 [AlbumSaveResult]，
/// 不向上抛，避免自动存相册流程打断任务状态机。
class AlbumSaver {
  const AlbumSaver._();

  /// 保存 [path] 指向的视频到相册。[title] 用作相册里的显示名（可选）。
  static Future<AlbumSaveResult> saveVideo(String path, {String? title}) async {
    try {
      final file = File(path);
      if (!await file.exists()) {
        return AlbumSaveResult(false, '文件不存在: $path');
      }

      final state = await PhotoManager.requestPermissionExtend();
      if (!state.hasAccess) {
        return AlbumSaveResult(false, '相册权限被拒绝: ${state.name}');
      }

      await PhotoManager.editor.saveVideo(file, title: title);
      return const AlbumSaveResult(true);
    } catch (e) {
      return AlbumSaveResult(false, '保存异常: $e');
    }
  }
}
