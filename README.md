# video_cacher

纯 Dart 实现的 Flutter 离线视频缓存包：无 ffmpeg、无 SQLite、无任何 native 二进制。

## 能力

- 下载 `mp4` 直链和 `m3u8`(HLS)，自动识别源类型
- 断点续传、暂停/继续/取消/优先、并发调度
- 通过 `setRefreshUrl` 回调刷新过期下载地址（404/410 自动触发）
- HLS AES-128 分片解密
- 纯 Dart 转封装（remux，不转码）：h264 + AAC 的 TS → 本地 `mp4`
- 任务用 JSON 持久化，App 重启可恢复
- 成片可自动/手动保存到系统相册（基于 photo_manager）

## 限制

- **h265(HEVC) 暂不支持**：h265 的 HLS 任务会以 `failed` 结束，错误信息形如
  `UnsupportedStreamException: video codec h265 not supported yet (only h264)`。
  下一版本计划支持。
- 音轨仅支持 AAC-ADTS。

## 安装

```yaml
dependencies:
  video_cacher: ^0.1.0
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

### 任务状态

`queued` / `running` / `remuxing` / `paused` / `completed` / `failed` / `canceled`

## URL 刷新约定

`setRefreshUrl` 在下载中遇到 `404` / `410` 时触发（HLS 的入口 m3u8、key、ts 三类地址都覆盖）。
回调参数是任务的 `taskId`，需返回完整可下载的新地址，不能为空。

## App 重启后的行为

- 任务从 JSON 存储恢复
- 之前处于 running/queued/remuxing 的任务统一转为 `paused`
- 不自动续传，需用户手动继续

## Example

示例工程在 `example/lib/` 下，演示了初始化、创建任务、列表管理、暂停/继续/删除、本地播放和相册保存。
