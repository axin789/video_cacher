import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../local_video_server.dart';
import '../model/m3u8_models.dart';

double _usToSec(int? us) => us == null ? 0.0 : us / 1e6;

Future<String> buildLocalM3U8WithRelativePath(M3u8Task task) async {
  final buf = StringBuffer()
    ..writeln('#EXTM3U')
    ..writeln('#EXT-X-VERSION:3')
    ..writeln('#EXT-X-TARGETDURATION:3') // 你可以动态计算
    ..writeln('#EXT-X-MEDIA-SEQUENCE:0');

  for (int i = 0; i < task.segments.length; i++) {
    final seg = task.segments[i];
    final name = p.basename(seg.localName);
    buf.writeln('#EXTINF:3.000,');
    buf.writeln(name); // 👈 只写文件名，不带 127.0.0.1
  }

  buf.writeln('#EXT-X-ENDLIST');

  final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/m3u8_task/${task.taskId}');

  final m3u8Path = p.join(dir.path, 'local.m3u8');
  await File(m3u8Path).writeAsString(buf.toString(), flush: true);
  return m3u8Path;
}
