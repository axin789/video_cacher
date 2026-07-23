import 'package:video_cacher/src/api/models/download_task.dart';
import 'package:video_cacher/src/api/models/task_status.dart';
import 'package:video_cacher/src/api/video_cacher.dart';
import 'package:flutter_test/flutter_test.dart';

DownloadTask _task({
  bool saveToAlbum = true,
  bool albumSaved = false,
  String? albumError,
  String? mp4Path = '/tmp/video.mp4',
}) =>
    DownloadTask(
      taskId: 't1',
      movieId: 't1',
      name: 't1',
      coverImg: '',
      url: 'https://cdn/a.mp4',
      dir: '/tmp/t1',
      kind: SourceKind.mp4,
      createdAtMs: 0,
      status: TaskStatus.completed,
      mp4Path: mp4Path,
      saveToAlbum: saveToAlbum,
      albumSaved: albumSaved,
      albumError: albumError,
    );

void main() {
  group('VideoCacher.shouldAutoSave', () {
    test('需要存 + 未存过 + 无失败记录 + 有 mp4 -> true', () {
      expect(VideoCacher.shouldAutoSave(_task()), isTrue);
    });

    test('saveToAlbum=false -> false', () {
      expect(VideoCacher.shouldAutoSave(_task(saveToAlbum: false)), isFalse);
    });

    test('已存过（albumSaved=true）-> false', () {
      expect(VideoCacher.shouldAutoSave(_task(albumSaved: true)), isFalse);
    });

    test('存过一次失败（albumError 非空）-> false，不再自动重试', () {
      expect(VideoCacher.shouldAutoSave(_task(albumError: '相册权限被拒')), isFalse);
    });

    test('手动重试成功后（albumSaved=true 且 albumError 已清）仍 false', () {
      expect(
        VideoCacher.shouldAutoSave(_task(albumSaved: true, albumError: null)),
        isFalse,
      );
    });

    test('mp4Path 为 null 或空串 -> false', () {
      expect(VideoCacher.shouldAutoSave(_task(mp4Path: null)), isFalse);
      expect(VideoCacher.shouldAutoSave(_task(mp4Path: '')), isFalse);
    });
  });
}
