import 'dart:typed_data';

import 'package:video_cacher/src/remux/dart_transmuxer/ts_demuxer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把 188 字节的 TS 包组装出来：4 字节头 + payload（自动补齐到 184）。
Uint8List _tsPacket({
  required int pid,
  required bool pusi,
  required List<int> payload,
  int cc = 0,
}) {
  final pkt = Uint8List(188)..fillRange(0, 188, 0xff);
  pkt[0] = 0x47;
  pkt[1] = (pusi ? 0x40 : 0) | ((pid >> 8) & 0x1f);
  pkt[2] = pid & 0xff;
  pkt[3] = 0x10 | (cc & 0x0f); // afc=1（仅 payload）
  for (int i = 0; i < payload.length && i < 184; i++) {
    pkt[4 + i] = payload[i];
  }
  return pkt;
}

/// 188 字节 TS 包，adaptation field 填充，payload 精确为传入字节（不足 184 不补 0xff）。
Uint8List _tsPacketAf({
  required int pid,
  required bool pusi,
  required List<int> payload,
  int cc = 0,
}) {
  final pkt = Uint8List(188);
  pkt[0] = 0x47;
  pkt[1] = (pusi ? 0x40 : 0) | ((pid >> 8) & 0x1f);
  pkt[2] = pid & 0xff;
  pkt[3] = 0x30 | (cc & 0x0f); // afc=3（AF + payload）
  final afLen = 184 - payload.length - 1;
  pkt[4] = afLen;
  if (afLen > 0) {
    pkt[5] = 0x00;
    for (int i = 6; i < 5 + afLen; i++) {
      pkt[i] = 0xff;
    }
  }
  pkt.setRange(5 + afLen, 188, payload);
  return pkt;
}

/// 5 字节 PTS 编码（PTS-only，guard bits = 0x2）。
List<int> _pts(int v) => [
      0x21 | (((v >> 30) & 0x7) << 1),
      (v >> 22) & 0xff,
      (((v >> 15) & 0x7f) << 1) | 1,
      (v >> 7) & 0xff,
      ((v & 0x7f) << 1) | 1,
    ];

List<int> _pat() => [
      0x00, // pointer_field
      0x00, // table_id
      0xb0, 0x0d, // section_length = 13
      0x00, 0x01, // transport_stream_id
      0xc1, // version/current_next
      0x00, 0x00, // section/last_section
      0x00, 0x01, // program_number = 1
      0xe1, 0x00, // reserved + PMT_PID = 0x0100
      0x00, 0x00, 0x00, 0x00, // CRC（parser 不校验）
    ];

List<int> _pmt() => [
      0x00, // pointer_field
      0x02, // table_id
      0xb0, 0x17, // section_length = 23
      0x00, 0x01, // program_number
      0xc1, 0x00, 0x00, // version/section/last
      0xe1, 0x00, // PCR_PID
      0xf0, 0x00, // program_info_length = 0
      0x1b, 0xe1, 0x01, 0xf0, 0x00, // video: type 0x1b, pid 0x0101
      0x0f, 0xe1, 0x02, 0xf0, 0x00, // audio: type 0x0f, pid 0x0102
      0x00, 0x00, 0x00, 0x00, // CRC
    ];

List<int> _videoPes(int pts) => [
      0x00, 0x00, 0x01, 0xe0, // start code + stream_id(video)
      0x00, 0x00, // PES_packet_length (unbounded)
      0x80, 0x80, 0x05, // marker, PTS-only flag, header_len=5
      ..._pts(pts),
      0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x77, // Annex-B IDR NAL
    ];

List<int> _audioPes(int pts) => [
      0x00, 0x00, 0x01, 0xc0, // start code + stream_id(audio)
      0x00, 0x00,
      0x80, 0x80, 0x05,
      ..._pts(pts),
      // 一个最小 ADTS 帧头（LC, 44.1k, 立体声, frameLen=8）+1 字节数据
      0xff, 0xf1, 0x50, 0x40, 0x01, 0x00, 0xfc, 0x00,
    ];

void main() {
  group('TsDemuxer', () {
    test('解析 PAT/PMT，识别 video/audio PID 与 stream_type', () {
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: _pmt()));
      d.feed(_tsPacket(pid: 0x0101, pusi: true, payload: _videoPes(9000)));
      d.feed(_tsPacket(pid: 0x0102, pusi: true, payload: _audioPes(9000)));
      d.finish();

      expect(d.pmtPid, 0x0100);
      expect(d.video, isNotNull);
      expect(d.audio, isNotNull);
      expect(d.video!.pid, 0x0101);
      expect(d.audio!.pid, 0x0102);
      expect(d.videoStreamType, TsStreamType.h264);
      expect(d.audioStreamType, TsStreamType.aacAdts);
    });

    test('重组 PES 并抽取 PTS/DTS', () {
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: _pmt()));
      d.feed(_tsPacket(pid: 0x0101, pusi: true, payload: _videoPes(12345)));
      d.finish();

      expect(d.video!.units.length, 1);
      final u = d.video!.units.first;
      expect(u.pts, 12345);
      expect(u.dts, 12345); // PTS-only -> dts=pts
      // PES header 被剥离，剩下 Annex-B 数据
      final data = u.data.toBytes();
      expect(data.sublist(0, 5), [0x00, 0x00, 0x00, 0x01, 0x65]);
    });

    test('两个 PUSI 切成两个 PES 单元', () {
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: _pmt()));
      d.feed(_tsPacket(pid: 0x0101, pusi: true, payload: _videoPes(1000)));
      d.feed(_tsPacket(pid: 0x0101, pusi: true, payload: _videoPes(4000)));
      d.finish();

      expect(d.video!.units.length, 2);
      expect(d.video!.units[0].pts, 1000);
      expect(d.video!.units[1].pts, 4000);
    });

    test('HEVC(0x24) 被识别为 video stream_type', () {
      final pmt = _pmt();
      pmt[13] = 0x24; // 把 video stream_type 改成 HEVC
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: pmt));
      d.finish();
      expect(d.videoStreamType, TsStreamType.hevc);
    });

    test('有界 PES：AU 跨两个 PES（续包无 PTS）合并回上一单元', () {
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: _pmt()));
      // PES 1：带 PTS，IDR 前半
      d.feed(_tsPacketAf(pid: 0x0101, pusi: true, payload: [
        0x00, 0x00, 0x01, 0xe0, 0x00, 0x0e, // PES_packet_length 有界
        0x80, 0x80, 0x05, ..._pts(9000),
        0x00, 0x00, 0x00, 0x01, 0x65, 0x11,
      ]));
      // PES 2：同一 AU 的续包，无 PTS
      d.feed(_tsPacketAf(pid: 0x0101, pusi: true, payload: [
        0x00, 0x00, 0x01, 0xe0, 0x00, 0x06,
        0x80, 0x00, 0x00, // 无 pts/dts，header_len=0
        0x22, 0x33, 0x44,
      ]));
      d.finish();

      expect(d.video!.units.length, 1);
      final u = d.video!.units.single;
      expect(u.pts, 9000);
      expect(u.data.toBytes(),
          [0x00, 0x00, 0x00, 0x01, 0x65, 0x11, 0x22, 0x33, 0x44]);
    });

    test('PMT section 跨两个 TS 包仍能解析', () {
      const pil = 200; // 描述符把 section 撑过一个 TS 包
      final section = <int>[
        0x02, // table_id
        0xb0, 0xdf, // section_length = 223 = 5+4+200+10+4
        0x00, 0x01, 0xc1, 0x00, 0x00,
        0xe1, 0x00, // PCR_PID
        0xf0, pil, // program_info_length
        ...List.filled(pil, 0x00),
        0x1b, 0xe1, 0x01, 0xf0, 0x00,
        0x0f, 0xe1, 0x02, 0xf0, 0x00,
        0x00, 0x00, 0x00, 0x00, // CRC
      ];
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(
          pid: 0x0100,
          pusi: true,
          payload: [0x00, ...section.sublist(0, 183)]));
      d.feed(
          _tsPacket(pid: 0x0100, pusi: false, payload: section.sublist(183)));
      d.finish();

      expect(d.video, isNotNull);
      expect(d.video!.pid, 0x0101);
      expect(d.audio!.pid, 0x0102);
      expect(d.videoStreamType, TsStreamType.h264);
    });

    test('非法超长 section_length 不抛 RangeError（按无 PSI 处理）', () {
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      expect(() {
        d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: [
          0x00, // pointer
          0x02, 0xbf, 0xff, // section_length = 0xfff
          0x00, 0x01, 0xc1, 0x00, 0x00, 0xe1, 0x00,
          0xf1, 0x00, // program_info_length = 256（越过 184 字节 payload）
        ]));
        d.finish();
      }, returnsNormally);
      expect(d.video, isNull); // 缺失 -> 上层最终报 Unsupported，而非崩溃
    });

    test('流尾截断的 PES 头不抛异常，之前的帧保留', () {
      final d = TsDemuxer();
      d.feed(_tsPacket(pid: 0, pusi: true, payload: _pat()));
      d.feed(_tsPacket(pid: 0x0100, pusi: true, payload: _pmt()));
      d.feed(_tsPacket(pid: 0x0101, pusi: true, payload: _videoPes(3000)));
      // 尾包：PES 头声明带 PTS 但 11 字节处被截断
      d.feed(_tsPacketAf(pid: 0x0101, pusi: true, payload: [
        0x00, 0x00, 0x01, 0xe0, 0x00, 0x00, 0x80, 0x80, 0x0a, 0x21, 0x00,
      ]));
      expect(() => d.finish(), returnsNormally);
      expect(d.video!.units.length, 1);
      expect(d.video!.units.single.pts, 3000);
    });
  });
}
