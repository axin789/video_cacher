import 'dart:io';
import 'package:photo_manager/photo_manager.dart';

class AlbumSaver {
  /// 返回 true=保存成功；false=失败/没权限
  static Future<bool> saveVideo(String filePath, {String? title}) async {
    final f = File(filePath);
    if (!await f.exists()) return false;

    final perm = await PhotoManager.requestPermissionExtend();
    if (!perm.isAuth) return false;

    final r = await PhotoManager.editor.saveVideo(
      f,
      title: title,
    );

    return r != null;
  }
}