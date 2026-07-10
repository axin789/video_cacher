# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

`video_cacher` 是一个纯 Dart 的 Flutter 离线视频缓存包（版本 0.1.0，无 native 代码、非插件）。核心能力：下载 mp4 直链和 m3u8(HLS)、断点续传、URL 过期刷新、HLS AES-128 解密、纯 Dart 转封装（remux，只换容器不转码）为本地 mp4、成片保存到系统相册。任务用 JSON 持久化，App 重启可恢复。

已知限制：transmuxer 仅支持 h264 + AAC；h265(HEVC) 任务会以 `failed` 结束（错误信息带 `UnsupportedStreamException`），计划下一版本支持。

## 常用命令

```bash
flutter pub get                    # 装依赖（主包 + example 各一次）
flutter analyze                    # 静态检查，主包和 example 都要过（用 flutter_lints）
flutter test                       # 运行单测（下载引擎/HLS/MP4/transmuxer golden/存储）
cd example && flutter run          # 运行示例 app（真机/模拟器）
```

要求 Flutter `>=3.3.0`、Dart SDK `>=3.6.0`。

手动验证清单见 [TESTING.md](TESTING.md)（MP4/HLS 流程、URL 过期恢复、remux 取消语义、h265 预期失败、相册保存、持久化恢复）。

## 架构主线

下载全链路：`VideoCacher`(单例门面) → `DownloadEngine` → `Mp4Downloader`/`HlsDownloader` → `DartTransmuxer` → JSON store + `taskStream`。

- **[VideoCacher](lib/src/api/video_cacher.dart)** — 唯一对外入口（`VideoCacher.instance`）。装配 Dio/HttpClient/UrlRefresher/引擎/存储，负责 enqueue（先 `SourceDetector` 识别源类型）、相册自动保存、`setRefreshUrl` 注入刷新回调。工作根目录 `<appDocs>/video_cacher`。
- **[DownloadEngine](lib/src/download/download_engine.dart)** — 任务内存表 + [TaskQueue](lib/src/download/task_queue.dart) 并发调度（默认 3）+ 事件广播。pause/cancel 用「意图登记 + CancelToken」实现；remux 阶段的取消经 `remuxer.cancel(taskId)` 软停，返回后重读状态，绝不用 completed 覆盖终态。冷启动 `loadFromStore` 把 running/queued/remuxing 统一降级为 `paused`，不自动续传。
- **[Mp4Downloader](lib/src/download/mp4/mp4_downloader.dart)** — HEAD + Range 流式下载断点续传（If-Range/ETag）。
- **[HlsDownloader](lib/src/download/hls/hls_downloader.dart)** — 解析 m3u8（master→media hop）、并发下 ts 分片（`segConcurrency: 2`）、AES-128 解密落盘。与 MP4 侧一样，404/410 经 [UrlRefresher](lib/src/download/http/url_refresher.dart)（single-flight + 重试）拿新地址续传；入口 m3u8、key、ts 三类 URL 都覆盖。
- **[DartTransmuxer](lib/src/remux/dart_transmuxer/dart_transmuxer.dart)** — 纯 Dart TS→MP4 转封装，实现 [Remuxer](lib/src/remux/remuxer.dart) 接口（唯一实现；未来 h265 实现同样遵循此接口）。TS demux → h264 AU/SPS/PPS + AAC ADTS → ISO-BMFF，mp4 原子写（.part → rename）。不支持的流抛 `UnsupportedStreamException`，任务落 `failed`。有 golden 测试（`test/remux/`，含 ffprobe/framemd5 对照，无 ffmpeg 环境自动跳过对照项）。
- **[JsonTaskStore](lib/src/store/json_task_store.dart)** — JSON 文件持久化（去抖写盘），测试用 [MemoryTaskStore](lib/src/store/memory_task_store.dart)。
- **[DownloadTask](lib/src/api/models/download_task.dart)** — 任务模型；对外事件为解耦的 [TaskEvent](lib/src/api/models/task_event.dart) 快照。状态见 [TaskStatus](lib/src/api/models/task_status.dart)：queued/running/remuxing/completed/paused/failed/canceled（持久化按 name 字符串，不依赖 index）。

## 日志开关

- 下载链路（engine/refresh/hls/mp4）：`VideoCacherLog.verbose`（[lib/src/log.dart](lib/src/log.dart)），log name 前缀 `video_cacher.*`。
- transmuxer：`DartTransmuxer.verbose`，log name `video_cacher.transmux`。

## 修改注意事项

- 冷启动恢复的任务**不自动续传**，需用户手动继续（见 `DownloadEngine.loadFromStore`）。
- URL 刷新回调 `setRefreshUrl` 由业务方注入，包本身不知道如何拿新地址。
- 相册保存不影响任务 `completed` 状态，失败原因记在 `albumError`；`_albumSaving` 防同一任务重复保存。相册能力靠 photo_manager，业务工程需自行配置权限（见 README）。
- 这是纯 Dart 包：不要引入 platform channel / native 目标；h265 支持应作为新的 `Remuxer` 实现落地。
