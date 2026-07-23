## 0.1.1

- 修复门面未使用按配置构建的 Dio 导致超时/User-Agent 失效（生产环境无任何超时）。
- 修复相册保存失败后无限自动重试：首次失败即停，仅可手动 `copyToAlbum` 重试。
- 修复任务存储并发写竞态与删除后复活（按 taskId 串行化写入）。
- URL 刷新回调增加超时（`refreshTimeout`，默认 30s），防止回调挂起泄漏并发槽。
- MP4 下载嗅探响应首块，m3u8 播放列表文本不再被误存成视频成片。
- 补齐 completed 状态守卫（pause/cancel 不再降级已完成任务）与完成提交前的取消/暂停意图复查。
- `ensureInitialized` 增加在飞守卫，并发调用不再双重初始化；`dispose` 顺序修正（先停引擎再关 HTTP）。
- 日志开关统一为 `VideoCacherLog.verbose` 并从包入口导出，宿主可一键静音全部日志。
- pointycastle 改为按需导入，减小 AOT 产物体积。

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
