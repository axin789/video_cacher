## 0.1.0

- 全新纯 Dart 重写：下载引擎（dio）、JSON 任务存储、纯 Dart transmuxer（h264+AAC TS → mp4）。
- 删除 ffmpeg 与全部 native 代码（Android .so / iOS xcframework / 各平台插件目标），不再是 Flutter 插件。
- 删除 SQLite，任务持久化改为 JSON。
- 包更名：`ffmpeg_remux` → `video_cacher`。
- 破坏性 API 变更：门面类 `DownloadManager` → `VideoCacher`，API 详见 README。
- 已知限制：h265(HEVC) 暂不支持，此类任务会 failed，下一版本支持。

## 0.0.5

- 将 README、测试清单和核心代码注释统一调整为中文。
- 补充并整理下载、刷新地址、相册复制等能力说明。

## 0.0.4

- improve example app structure by splitting pages and widgets into separate files
- add download list UI with completed and processing tabs
- add local video playback in the example app
- add detailed album copy result reporting and clearer failure reasons
- add manual retry flow for failed tasks through `setRefreshUrl`
- keep unfinished tasks paused after app restart instead of auto-resuming
- refine same-id task handling in the example UI
- improve README and example text for integration guidance

## 0.0.1

* TODO: Describe initial release.

## 0.0.2
- android so 集成一个
- iOS 打成标准库
- 更新了依靠参数决定是否把mp4复制到相册

## 0.0.3
- 支持web空实现编译无法编译
