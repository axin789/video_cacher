# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

`ffmpeg_remux` 是一个 Flutter 离线视频缓存插件（版本 0.0.5）。核心能力：下载 mp4 直链和 m3u8(HLS)、断点续传、URL 过期刷新、HLS 用 FFmpeg 转封装（remux，只换容器不转码）为本地 mp4、成片复制到系统相册。任务通过 SQLite 持久化，App 重启可恢复。

平台支持：Android / iOS 为主，macOS 有插件目标但非主场景，Web 仅空实现保证编译通过。

## 常用命令

```bash
flutter pub get                    # 装依赖（主包 + example 各一次）
flutter analyze                    # 静态检查，主包和 example 都要过（用 flutter_lints）
cd example && flutter run          # 运行示例 app（真机/模拟器）
flutter test                       # 运行 Dart 测试（当前主包无 test/，测试主要靠 example 手测）
```

要求 Flutter `>=3.3.0`、Dart SDK `>=3.6.0`。README 与 TESTING.md 提到实测基线为 Flutter 3.27.4。

Android 构建约束（业务工程需对齐）：`compileSdk = 36`、`ndkVersion = "27.0.12077973"`、`minSdk = 24`。原生 `.so` 仅提供 `arm64-v8a`。

手动验证清单见 [TESTING.md](TESTING.md)（MP4/HLS 流程、URL 过期恢复、remux 取消语义、相册复制、持久化恢复）。当前没有自动化测试，改动后按该清单在 example 里手测。

## 架构主线

下载全链路：`DownloadManager`(单例) → `DownloadScheduler` → `HlsWorker`/`Mp4Worker` → `PostProcessor` → 落盘 + SQLite + `taskStream`。

- **[DownloadManager](lib/download/download_manager.dart)** — 唯一对外入口（`DownloadManager.instance`）。管理任务内存表 `_tasks`、SQLite `store`、`taskStream`（广播 `M3u8Task` 状态变化给 UI）。负责相册自动保存、按平台选择 PostProcessor、冷启动恢复。业务方通过 `setRefreshUrl` 注入 URL 刷新回调。`enqueue` 是简化入口，内部走 `addOrResumeFormMeta`。
- **[DownloadScheduler](lib/download/download_scheduler.dart)** — 并发调度，默认最多 3 个并发（`maxActiveVideos`）。用 `_queue`（等待）+ `_active`（运行中）+ `_pump()`（微任务泵）驱动。按 `task.kind` 创建 HLS/MP4 worker。pause/cancel/resume/prioritize 都在这里落地。**注意**：`setMaxConcurrency` 会重建整个 scheduler 实例。
- **[HlsWorker](lib/download/worker/hls_worker.dart)** / **[Mp4Worker](lib/download/worker/mp4_worker.dart)** — 实现 [BaseWorker](lib/download/worker/base_worker.dart)。HLS 解析 m3u8、并发下 ts 分片（`segConcurrency: 2`）、处理 AES key，完成后写 local.m3u8 交给 PostProcessor remux；MP4 走 HEAD + Range 流式下载断点续传。两者都在分片/流阶段遇到 404/410 时调 `refreshUrl` 拿新地址续传。
- **[PostProcessor](lib/download/processor/post_processor.dart)** — HLS 下载完后的转封装抽象。Android 用 [AndroidRemuxPostProcessor](lib/download/processor/android_remux_post_processor.dart)（同步 FFmpeg remux，可取消）；iOS 用 [IosPostProcessor](lib/download/processor/ios_post_processor.dart)（异步 remux，靠 EventChannel 回进度）。成功后 `cleanup` 删掉 ts/key/local.m3u8 只留 mp4。
- **[M3u8Task](lib/download/model/m3u8_models.dart)** — 贯穿全链路的任务模型，同时承载 HLS 字段（segments/key/hlsLocalM3u8Path）和 MP4 字段（contentLength/downloaded/eTag/tmpPath），以及产物、相册、进度、状态（`TaskStatus`）。
- **[TaskStore](lib/download/task_store/)** — SQLite 持久化，条件导入：`task_store_io.dart`（移动端，sqlite3）/ `task_store_web.dart`（web 空实现），由 [task_store.dart](lib/download/task_store/task_store.dart) 选择。用 `upsertTask` 增量写单条，避免全量刷。

## 原生桥接（关键，改动前务必理解）

**Android 与 iOS 的 MethodChannel 名故意不一致，改了会断桥：**

- **Android** — channel `ffmpeg_remux/methods`（method）+ `ffmpeg_remux/progress`（event）。Dart 侧 [FfmpegRemux](lib/ffmpeg_remux.dart) 调用。原生 [FfmpegRemuxPlugin.kt](android/src/main/kotlin/com/media/ffmpeg_remux/FfmpegRemuxPlugin.kt) 通过 `System.loadLibrary("ffmpeg_remux")` + JNI `external fun remuxM3u8ToMp4(...)` 调 `libffmpeg_remux.so`（仅 arm64-v8a）。remux 是**真正可中断**的（AtomicBoolean + interrupt）。
- **iOS** — channel `ffmpeg_remux`（method）+ `ffmpeg_remux/progress`（event）。Dart 侧 [FfmpegRemuxIos](lib/ffmpeg_remux_ios.dart) 调用。原生 [FfmpegRemuxPlugin.swift](ios/Classes/FfmpegRemuxPlugin.swift) 通过 `@_silgen_name("remux_m3u8_to_mp4")` 直连 C 函数，链接 `ios/FFmpegMinXC/*.xcframework`（libavformat/libavutil/libavcodec）。iOS remux 在后台线程异步执行。
- **iOS 取消是"软取消"**：C 层不可中断，`cancelRemux` 只是打标记，UI 靠 `state=canceled` 兜底；Android 是真正停止。
- **iOS 本地 HTTP server**：[LocalVideoServer](lib/download/local_video_server.dart) 在 `127.0.0.1:18080` 起服务，支持本地 m3u8 的 Range 播放（`ensureInitialized` 时在 iOS 上启动）。

## 修改注意事项

- 冷启动时，SQLite 里 running/queued/postProcessing 的任务会统一转成 `paused`，**不自动续传**，需用户手动继续（见 `ensureInitialized` 尾部）。
- URL 刷新回调 `setRefreshUrl` 由业务方注入，插件本身不知道如何拿新地址；HLS 的入口 m3u8、key、ts 三种 URL 过期都会触发刷新。
- 相册保存不影响任务 `completed` 状态，失败原因记在 `albumError`；`_albumSaving` 防同一任务重复保存。
- Web/macOS 是桩实现，不要在这两端指望真实下载/remux 能力。
