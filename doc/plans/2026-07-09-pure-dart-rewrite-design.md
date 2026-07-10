# ffmpeg_remux 全新重写设计（纯 Dart 化）

> 定稿日期：2026-07-09
> 状态：已与作者确认，待进入实施计划

## Overview

把 `ffmpeg_remux` 从「Dart 下载 + native ffmpeg remux + SQLite」的混合插件，重写为**近乎 100% 纯 Dart 的离线视频缓存包**：Dart 下载 + **Dart transmuxer（TS→MP4）** + **JSON 存储**。目标是**极致小体积、稳定、Android + iOS 一套代码、web 空实现**。

核心结论（决策已定）：

- **不下沉 native**。让 remux 只做「本地文件容器转换」，用纯 Dart transmuxer 替代 ffmpeg，从而**删除全部 native 代码**（Android JNI `.so`、iOS/macOS xcframework、iOS 本地 HTTP server、native plugin）。
- **删掉 SQLite**，改为「每任务一个 JSON 文件 + 原子写 + 去抖」。`sqlite3_flutter_libs` 会打包 native 二进制，与小体积目标冲突，且数据量极小用不上 SQL。
- **仅 remux 不转码**。h264 / h265 都只搬运裸流不解码，目标设备播放器自行硬解。体积不受编解码器影响。
- **全新重写**，允许重设计对外 API。

## 已确认的输入约束

| 项 | 结论 |
|---|---|
| 视频类型 | mp4 直链 + m3u8(HLS) |
| HLS 分片容器 | **MPEG-TS (.ts)**（非 fMP4） |
| HLS 加密 | **AES-128 整片加密**（非 SAMPLE-AES） |
| 编码 | h264 与 h265 混合，**仅 remux 不转码** |
| CDN | 链接约 30 分钟过期成 404，需回调业务方刷新 |
| 平台 | Android + iOS 为主，web 不支持下载（空实现） |
| 体积 | 极致小 —— 首要目标 |
| 真实样本 | 作者稍后提供 m3u8 地址用于原型验证 |

## 架构

这是 SDK/库，不是 App，**不强套 presentation 层**（UI 由接入方负责）。采用务实分层：

```
lib/
  ffmpeg_remux.dart                 # 公开 API 门面（barrel）
  src/
    api/
      download_manager.dart         # 对外门面
      models/                       # 不可变 DTO: DownloadTask / TaskStatus / TaskEvent / DownloadConfig
    download/
      download_engine.dart          # 调度编排（合并原 scheduler + manager）
      task_queue.dart               # 并发控制（默认 3）
      source_detector.dart          # mp4 / hls 识别
      http/
        http_client.dart            # dio 封装：Range、重试、404→刷新钩子
        url_refresher.dart          # 包裹业务 setRefreshUrl：单飞去重 + 退避 + 上限
      mp4/mp4_downloader.dart       # Range 断点续传
      hls/
        m3u8_parser.dart            # variant + media playlist
        hls_downloader.dart         # 分片并发下载
        aes_decryptor.dart          # AES-128 整片解密
    remux/
      remuxer.dart                  # 接口：decrypted TS → mp4
      dart_transmuxer/              # ★ 纯 Dart TS→MP4（本次核心）
        ts_demuxer.dart             #   TS packet → PES → ES
        h264_parser.dart            #   NAL/SPS/PPS → avcC
        h265_parser.dart            #   NAL/VPS/SPS/PPS → hvcC
        aac_adts.dart               #   AAC ADTS → esds
        mp4_builder.dart            #   ISO-BMFF 写出（moov/mdat/stbl/ctts…）
      ffmpeg_fallback/              # 兜底：可插拔 native remux（默认不启用）
    store/
      task_store.dart               # 接口
      json_task_store.dart          # 每任务一个 JSON，原子写 + 去抖（io）
      memory_task_store.dart        # web 空实现
    album/album_saver.dart          # photo_manager 封装
```

`remux/remuxer.dart` 为接口，默认实现 `DartTransmuxer`；`ffmpeg_fallback` 是同接口兜底实现，de-risk 阶段两者 A/B，Dart 版验证通过后删除 native。

### 依赖变化

- **删除**：`sqlite3`、`sqlite3_flutter_libs`。iOS 本地 server 相关代码删除。
- **保留**：`dio`、`path`、`path_provider`、`crypto`（AES-128）、`flutter_hls_parser`（或自研 m3u8 parser，视原型而定）、`photo_manager`。
- 移除全部 native 后，本包不再是 Flutter plugin，退化为普通 Dart package（仍间接依赖别人的插件）。

## 数据流

### MP4
`enqueue → source_detector=mp4 → mp4_downloader（HEAD 取长度/ETag → Range 分块流式下载，断点续传）→ 完成 → 落 mp4Path → 可选存相册`

### HLS
`enqueue → source_detector=hls → m3u8_parser（variant→media）→ hls_downloader（并发下 ts，AES-128 整片解密）→ 全部落盘 → DartTransmuxer（TS→MP4）→ 落 mp4Path → cleanup 删 ts/key → 可选存相册`

### 404 刷新状态机（稳定性核心）
- `url_refresher` 对**同一 taskId 的刷新单飞**（并发 404 只触发一次业务回调），带退避 + 次数上限，防刷新风暴。
- 任何请求（mp4 HEAD/GET、m3u8 入口、key、ts）拿到 404/410 → 调 refresher 拿新入口 URL → **重解析 playlist、把剩余分片重映射到新 token/域名** → 从断点续传，不重下已完成分片。
- 取消/暂停用协作式 CancelToken 贯穿。**iOS「软取消」bug 因 remux 变 Dart 从根上消失**。

## 状态与事件模型

- **不可变** `TaskEvent` 快照（taskId, status, progress 0..1, downloadedBytes, totalBytes, error）通过单一 broadcast stream 抛出。替换现有「把可变 M3u8Task 直接当事件抛」的做法（一类 bug 源），内部状态用 `copyWith`。
- `TaskStatus`：queued / running / remuxing / completed / paused / failed / canceled。
- 冷启动：running/queued/remuxing → 统一转 `paused`，不自动续传（沿用现有语义）。

## 持久化

- **每任务一个 JSON 文件**，`store/tasks/<taskId>.json`，原子写（写 `.tmp` 再 rename）+ 去抖（状态变更立即写；进度最多每 ~1s 写一次）。
- **断点续传不持久化分片完成情况**：从磁盘扫任务目录里存在哪些 `.ts` 推导。JSON 只存：任务列表 + 状态 + 元数据（name/cover/movieId 等）+ 当前 URL + mp4 产物路径 + 相册状态。
- web：`memory_task_store` 空实现。

## Dart transmuxer（最大风险点）

处理链：`解密后 TS 字节 → ts_demuxer 拆 PES → 按 PID 分离 h264/h265 视频 + AAC 音频 → 解析 SPS/PPS/VPS 生成 avcC/hvcC → mp4_builder 写 moov(stts/stss/ctts/stsc/stsz/stco/elst) + mdat`。

> **2026-07-09 原型验证结论（H.264+AAC 已过 de-risk 闸门，字节级无损）**：真实样本（2.5K h264 High + B 帧 + AAC-LC）产出的 mp4 与 ffmpeg `-c copy` **逐帧 framemd5 全等、PSNR=inf**。纯 Dart 约 700 行、仅 `dart:io`+`dart:typed_data`。

必须正确处理（按实测风险从高到低）：
- **★ edit list(`elst`) + 音视频全局时间基线**（原型真正踩的坑，"能播但静默错误"）：非分片 MP4 解码时间轴从 0 起，视频轨初始解码偏移无处存；两轨须以**单一全局最小时间戳**基线，否则 A/V 漂移。空编辑长度=minPTS，再接 media_time=最小 composition 偏移；写成 `media_time=0` 会被 ffmpeg 丢掉前导帧。
- **B 帧的 CTS 偏移**（ctts box）：ctts[i]=PTS[i]−DTS[i]，样本按 DTS 顺序存。实测**不难，一次即对**（TS 每个 PES 恰好一个 AU，PTS/DTS 直接取自 PES 头）。
- **PTS 33-bit 环绕**（长视频）。
- `stss` 必须列全 IDR，否则 seek 坏。
- `co64` 兜底（>4GB）。
- h265 增量：`hvcC` 装 **VPS+SPS+PPS 三组**、NAL 头 **2 字节**、IDR 判定 NAL type 16–23、AU 边界需 2 字节头逻辑——同架构加一块，须用真 h265 B 帧流重验。

参考成熟实现 `hls.js` / `mux.js` 的 transmux 逻辑移植。原型 `transmux.dart` 存于会话 scratchpad，可作实现参考。

## 测试策略（priority 排序）

1. **单元（核心）**：
   - `m3u8_parser`（fixture 播放列表）
   - `ts_demuxer`（字节 fixture → 期望 PES/ES）
   - `mp4_builder`（产出 mp4，校验 box 结构）
   - `aes_decryptor`（已知向量）
   - **`url_refresher` / 404 状态机**（mock http 先 404 后 200，断言只刷一次、正确续传）
   - 断点续传（模拟半截 .ts / 半截 mp4 + ETag）
   - `json_task_store` 原子写（模拟写一半崩溃后可恢复）
2. **golden**：已知 `.ts` → 产出 `.mp4`，用真实播放器（example）或 ffprobe（CI）验证可播、时长/帧数正确。
3. **集成**：扩展 [TESTING.md](../../TESTING.md) 手测矩阵。

## De-risk 闸门

**在全量押注 Dart transmuxer 前**：拿作者真实样本做独立原型——h264 与 h265 各产出一个 mp4 且能正常播放 → 才替换 remux 并删 native。**不过关**则 remux 走 `ffmpeg_fallback`（保留现有 native），其余纯 Dart 化照常推进。

## 实施顺序

1. 搭骨架 + 不可变模型 + JSON store + 下载层（HLS/MP4/404 状态机）；remux 先复用现有 native，让全链路先端到端跑通。
2. 并行做 transmuxer 原型，用真实样本过 de-risk 闸门。
3. 原型过关 → 用 `DartTransmuxer` 替换 remux 接口实现 → **删除全部 native 代码**（.so / xcframework / native plugin / iOS local server / macos）。
4. 补齐测试矩阵，扩 example 验证，更新 README/TESTING/CLAUDE.md 与 pubspec（去 sqlite、去 plugin 声明）。

## 开放项（不阻塞）

- **包名**：`ffmpeg_remux` 去 ffmpeg 后名不副实。保留（省 pub 迁移）或改名，待作者定。
- **transmuxer 输入粒度**：整片解密后一次性喂 vs 流式喂，视原型内存表现定。
- **是否保留 ffmpeg_fallback 长期存在**：取决于线上是否出现 transmuxer 覆盖不到的流。
