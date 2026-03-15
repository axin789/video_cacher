import 'dart:io';
import 'package:photo_manager/photo_manager.dart';

class AlbumSaveResult {
  final bool ok;
  final String? error;
  const AlbumSaveResult(this.ok, [this.error]);
}

class AlbumSaver {
  /// 兼容旧接口
  static Future<bool> saveVideo(String filePath, {String? title}) async {
    final r = await saveVideoWithResult(filePath, title: title);
    return r.ok;
  }

  /// 新接口：返回详细失败原因，便于真机排查
  static Future<AlbumSaveResult> saveVideoWithResult(String filePath,
      {String? title}) async {
    try {
      final f = File(filePath);
      if (!await f.exists()) {
        return AlbumSaveResult(false, 'file not exists: $filePath');
      }

      final size = await f.length();
      if (size <= 0) {
        return AlbumSaveResult(false, 'file is empty: $filePath');
      }

      final perm = await PhotoManager.requestPermissionExtend();
      if (!perm.hasAccess) {
        return AlbumSaveResult(false, 'photo permission denied: $perm');
      }

      final asset = await PhotoManager.editor.saveVideo(
        f,
        title: title,
      );
      final exists = await asset.exists;
      if (!exists) {
        return AlbumSaveResult(
          false,
          'saved asset not found, path=$filePath, size=$size',
        );
      }
      return const AlbumSaveResult(true);
    } catch (e) {
      return AlbumSaveResult(false, 'saveVideo exception: $e');
    }
  }
}
