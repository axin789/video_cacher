# video_cacher

纯 Dart 实现的 Flutter 离线视频缓存包：无 ffmpeg、无 SQLite、无任何 native 二进制。

**English** — `video_cacher` is a pure-Dart Flutter package for offline video
caching. It downloads direct mp4 links and HLS (m3u8) streams with resumable
downloads, expired-URL refresh and AES-128 segment decryption, then remuxes the
TS segments into a local mp4 (h264 + AAC, no transcoding) inside a background
isolate, and can optionally save the result to the system photo album. No
ffmpeg, no SQLite, no native binaries.

```yaml
dependencies:
  video_cacher: ^0.2.0
```

```dart
final cacher = VideoCacher.instance;
await cacher.ensureInitialized();

final task = await cacher.enqueue(
  id: 'video_1001',
  name: 'Episode 1',
  cover: 'https://example.com/cover.jpg',
  url: 'https://example.com/play.m3u8',
);
cacher.taskStream.listen((e) {
  print('task=${e.taskId} status=${e.status.name} progress=${e.progress}');
});
```

The rest of this document is in Chinese.

## 能力

- 下载 `mp4` 直链和 `m3u8`(HLS)，自动识别源类型；识别错误可自愈——mp4 任务
  嗅探到 m3u8 内容会自动纠正为 HLS 流程，同一轮完成
- 断点续传：ETag 持久化 + `If-Range` 校验内容未变，服务端内容变更时自动从 0 重下；
  mp4 流中途瞬断按 Range 有限重试
- 暂停/继续/取消/插队、并发调度（任务级 + HLS 分片级并发均可配）
- 通过 `setRefreshUrl` 回调刷新过期下载地址（404/410 自动触发，覆盖
  入口 m3u8、key、ts、mp4 四类地址）；刷新后 HLS 变体按带宽锁定，不混码率
- HLS AES-128 分片解密（每片在独立 isolate 中解密，不卡主线程）
- 纯 Dart 转封装（remux，不转码）：h264 + AAC 的 TS → 本地 `mp4`；
  跑在独立 isolate（主线程零冻结），mdat 流式落盘（内存峰值约 1 倍输入），
  取消立即生效
- 进度事件按任务节流（约 10 次/秒），remuxing 阶段有逐分片真实进度
- 任务用 JSON 持久化，App 重启可恢复
- 成片可自动/手动保存到系统相册（基于 photo_manager）

## 进度语义

`downloadedBytes` / `totalBytes` 的量纲随阶段变化，`progress` 恒为 0..1：

| 阶段 | downloadedBytes / totalBytes 含义 |
|---|---|
| mp4 下载（running） | 已下载字节 / 文件总字节 |
| HLS 下载（running） | 已完成分片数 / 总分片数 |
| remuxing | 已喂入的输入字节 / 分片总输入字节（第二段 0..1） |
| completed | 回填为最终 mp4 文件字节数（两者相等） |

总长未知（如服务端不回 content-length）时 `totalBytes` 为 0、`progress` 为 0。
UI 若要单一进度条，可按状态把 running 与 remuxing 两段各自映射后拼接。

## 已知限制

- **h265(HEVC) 暂不支持**（支持计划中）：remux 在**首个含 PMT 的分片**即
  fail-fast，不会空跑完全部分片；error 形如
  `UnsupportedStreamException: PMT stream types: [...] — only h264+aac supported`。
  音轨仅支持 AAC-ADTS。
- **不支持的 HLS 播放列表特性会在下载任何分片前明确报错**
  （`UnsupportedPlaylistException`），不再静默产出坏数据：
  非 AES-128 加密（如 SAMPLE-AES）、key 轮换（多个不同 EXT-X-KEY）、
  `EXT-X-MAP`(fMP4)、`EXT-X-BYTERANGE`、`EXT-X-DISCONTINUITY`。
- 音频时间轴间隙不补偿：源流音频有缺口时，成片可能出现渐进音画偏移。
- 磁盘高水位约 2× 视频大小：分片与成片并存，remux 成功后才清理分片。
- 单文件 >4GB 未支持（mp4 box 使用 32 位长度）。

## 安装

```yaml
dependencies:
  video_cacher: ^0.2.0
```

## 权限说明

保存相册依赖 photo_manager，需要以下权限。

### Android

```xml
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />
```

### iOS

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>需要把导出的视频保存到系统相册。</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>需要访问相册以保存和查看导出的视频。</string>
```

## 快速开始

### 1. 初始化

```dart
final cacher = VideoCacher.instance;

cacher.setRefreshUrl((id) async {
  // 根据业务 id 向你自己的后端查询最新可下载地址。
  final result = await api.fetchLatestPlayUrl(id);
  return result.url;
});

await cacher.ensureInitialized();
```

### 2. 创建任务

```dart
final task = await cacher.enqueue(
  id: 'video_1001',
  name: '第 1 集',
  cover: 'https://example.com/cover.jpg',
  url: 'https://example.com/play.m3u8',
  saveToAlbum: false,
);
```

### 3. 监听任务事件

```dart
final sub = cacher.taskStream.listen((e) {
  print('task=${e.taskId} status=${e.status.name} progress=${e.progress}');
});
```

### 4. 常用控制

```dart
cacher.pause(task.taskId);
cacher.resume(task.taskId);
cacher.prioritize(task.taskId);
await cacher.cancel(task.taskId, deleteFiles: true);
await cacher.deleteTask(task.taskId);
await cacher.setMaxConcurrency(3);
```

### 5. 保存到相册

```dart
final result = await cacher.copyToAlbum(task.taskId);
print('ok=${result.ok}, error=${result.error}');

// 也可以直接按本地路径保存：
await cacher.copyPathToAlbum(task.mp4Path!, title: task.name);
```

## 日志开关

`VideoCacherLog.verbose` 控制全部下载/remux 链路日志，默认开启；
release 构建建议关闭：

```dart
VideoCacherLog.verbose = false;
```

## API 概览

### VideoCacher

- `setRefreshUrl(Future<String> Function(String id)? fn)`
- `ensureInitialized({DownloadConfig config})`
- `enqueue({required id, required name, required cover, required url, bool saveToAlbum = true})`
- `pause(String taskId)` / `resume(String taskId)` / `prioritize(String taskId)`
- `cancel(String taskId, {bool deleteFiles = false})`
- `deleteTask(String taskId)`
- `setMaxConcurrency(int n)`
- `copyToAlbum(String taskId)` / `copyPathToAlbum(String path, {String? title})`
- `taskStream` — `Stream<TaskEvent>`
- `tasks` — `Map<String, DownloadTask>` 只读快照
- `dispose()`

### 任务状态

`queued` / `running` / `remuxing` / `paused` / `completed` / `failed` / `canceled`

## URL 刷新约定

`setRefreshUrl` 在下载中遇到 `404` / `410` 时触发（HLS 的入口 m3u8、key、ts 与
mp4 直链都覆盖）。回调参数是任务的 `taskId`，需返回完整可下载的新地址，不能为空。
单次回调有超时（`DownloadConfig.refreshTimeout`，默认 30s），挂起按该次失败处理。

## App 重启后的行为

- 任务从 JSON 存储恢复
- 之前处于 running/queued/remuxing 的任务统一转为 `paused`
- 不自动续传，需用户手动继续

## Example

示例工程在 `example/lib/` 下，演示了初始化、创建任务、列表管理、暂停/继续/删除、本地播放和相册保存。
