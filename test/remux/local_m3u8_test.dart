import 'package:ffmpeg_remux/src/remux/local_m3u8.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildLocalM3u8', () {
    test('header 完整且以 ENDLIST 收尾', () {
      final out = buildLocalM3u8(['/tmp/seg_0.ts']);
      final lines = out.split('\n');
      expect(lines[0], '#EXTM3U');
      expect(lines[1], '#EXT-X-VERSION:3');
      expect(out, contains('#EXT-X-TARGETDURATION:'));
      expect(out, contains('#EXT-X-MEDIA-SEQUENCE:0'));
      expect(out.trimRight().endsWith('#EXT-X-ENDLIST'), isTrue);
    });

    test('每个分片一行 EXTINF + 一行路径，顺序保留', () {
      final segs = ['/a/seg_0.ts', '/a/seg_1.ts', '/a/seg_2.ts'];
      final out = buildLocalM3u8(segs);
      final extinfCount = '#EXTINF:'.allMatches(out).length;
      expect(extinfCount, segs.length);
      for (final s in segs) {
        expect(out, contains('#EXTINF:10.0,\n$s\n'));
      }
      // 路径按输入顺序出现
      final idx0 = out.indexOf(segs[0]);
      final idx1 = out.indexOf(segs[1]);
      final idx2 = out.indexOf(segs[2]);
      expect(idx0 < idx1 && idx1 < idx2, isTrue);
    });

    test('不写 EXT-X-KEY（分片已解密）', () {
      final out = buildLocalM3u8(['/a/seg_0.ts', '/a/seg_1.ts']);
      expect(out, isNot(contains('#EXT-X-KEY')));
    });

    test('路径原样保留，不做转义', () {
      const weird = '/data/user/0/app/files/task 1/seg_0.ts';
      final out = buildLocalM3u8([weird]);
      expect(out, contains('\n$weird\n'));
    });

    test('TARGETDURATION 为名义时长向上取整', () {
      final out = buildLocalM3u8(['/a/seg_0.ts'], nominalDurationSec: 6.5);
      expect(out, contains('#EXT-X-TARGETDURATION:7'));
    });

    test('空分片列表也产生合法骨架', () {
      final out = buildLocalM3u8([]);
      expect(out, contains('#EXTM3U'));
      expect(out, contains('#EXT-X-ENDLIST'));
      expect(out, isNot(contains('#EXTINF:')));
    });
  });
}
