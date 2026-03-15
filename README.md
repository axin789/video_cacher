# ffmpeg_remux

一个用于 Flutter 的离线视频缓存插件，主要能力包括：

- 下载 `mp4` 和 `m3u8`
- 使用 SQLite 持久化下载任务
- 通过业务回调刷新过期下载地址
- 将 HLS 内容转封装为本地 `mp4`
- 把最终 `mp4` 复制到系统相册

适合需要断点续传、离线缓存、HLS 转 MP4 的移动端场景。

## 功能特性

- 同时支持 `mp4` 和 `m3u8`
- 自动识别资源类型
- 本地持久化任务列表
- 支持暂停、手动继续、删除
- 支持通过 `setRefreshUrl` 自定义刷新下载地址
- 支持手动复制到相册和下载完成后自动复制
- 通过任务流把状态变化抛给下载列表 UI

## 平台支持

- Android：支持
- iOS：支持
- macOS：有插件目标，但主要使用场景仍是移动端
- Web：仅提供空实现，保证编译通过

## 安装

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  ffmpeg_remux: ^0.0.5
```

然后执行：

```bash
flutter pub get
```

## 权限说明

### Android

如果需要复制到相册，请在业务工程的 `AndroidManifest.xml` 中添加这些权限：

```xml
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />
```

如果你的工程直接依赖这个插件模块，请让业务工程的 Android 配置和插件要求保持一致：

- `compileSdk = 36`
- `ndkVersion = "27.0.12077973"`
- `minSdk = 24`

### iOS

如果需要复制到相册，请在 `Info.plist` 中添加：

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>需要把导出的视频保存到系统相册。</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>需要访问相册以保存和查看导出的视频。</string>
```

## 快速开始

### 1. 初始化

```dart
final mgr = DownloadManager.instance;

mgr.setRefreshUrl((id) async {
  // 根据业务 id 向你自己的后端查询最新可下载地址。
  // 例如：
  // final result = await api.fetchLatestPlayUrl(id);
  // return result.url;
  throw UnimplementedError();
});

await mgr.ensureInitialized();
await mgr.setMaxConcurrency(3);
```

### 2. 创建任务

```dart
final task = await mgr.enqueue(
  id: 'video_1001',
  name: '第 1 集',
  cover: 'https://example.com/cover.jpg',
  url: 'https://example.com/play.m3u8',
  saveToAlbum: false,
);
```

### 3. 监听任务变化

```dart
final sub = mgr.taskStream.listen((task) {
  print(
    'task=${task.taskId} '
    'status=${task.status.name} '
    'local=${task.localPath} '
    'error=${task.error}',
  );
});
```

### 4. 常用控制

```dart
mgr.pause(task.taskId);
mgr.resumeById(task.taskId);
await mgr.retryFailedTaskById(task.taskId);
await mgr.deleteTaskById(task.taskId);
```

### 5. 复制到相册

```dart
final result = await mgr.copyToAlbumWithResult(task.taskId);
print('ok=${result.ok}, error=${result.error}');
```

也可以直接按本地路径复制：

```dart
final result = await mgr.copyPathToAlbumWithResult(
  task.mp4Path!,
  title: task.name,
);
```

## API 概览

### DownloadManager

- `setRefreshUrl(Future<String> Function(String id)? fn)`
- `ensureInitialized()`
- `setMaxConcurrency(int n)`
- `enqueue({required id, required name, required cover, required url, bool saveToAlbum = true})`
- `pause(String taskId)`
- `resumeById(String taskId)`
- `retryFailedTaskById(String taskId, {String? overrideUrl})`
- `deleteTaskById(String taskId)`
- `copyToAlbum(String taskId)`
- `copyToAlbumWithResult(String taskId)`
- `copyPathToAlbum(String mp4Path, {String? title})`
- `copyPathToAlbumWithResult(String mp4Path, {String? title})`
- `taskStream`
- `tasks`

### 任务状态

当前支持的任务状态：

- `queued`
- `running`
- `paused`
- `completed`
- `failed`
- `canceled`
- `postProcessing`

## URL 刷新约定

`setRefreshUrl` 会在两个场景触发：

- 下载过程中遇到 `404` / `410` 这类资源过期错误时
- 失败任务被手动重试时

回调参数是当前任务的 `taskId`：

```dart
Future<String> refreshUrl(String id)
```

建议满足这些约定：

- 返回完整可下载的 `mp4` 或 `m3u8` 地址
- 返回值不能为空
- 如果是 HLS，刷新后的播放列表结构最好尽量稳定，便于续传

业务接入示例：

```dart
mgr.setRefreshUrl((id) async {
  final task = mgr.tasks[id];
  if (task == null) return '';

  final result = await api.fetchLatestPlayUrl(
    movieId: task.movieId,
    lid: task.lid,
  );
  return result.url;
});
```

## 任务行为

### 相同 `id` 的处理规则

如果同一个 `id` 已经存在：

- 已完成任务：视为已经下载过
- 进行中或暂停中的任务：视为已经在下载列表中
- 失败任务：允许重试，重试时可以刷新内部 URL

### App 重启后的行为

未完成任务在冷启动后不会自动继续下载。

App 重启后：

- 未完成任务会从 SQLite 恢复
- 之前处于运行中的任务会统一改成 `paused`
- 需要用户手动在下载列表里点击继续

## 相册复制错误

插件会返回更细的相册复制结果，例如：

- `file not exists`
- `file is empty`
- `photo permission denied`
- `saved asset not found`
- `saveVideo exception: ...`

建议在 UI 中使用 `copyToAlbumWithResult` 或 `copyPathToAlbumWithResult` 直接展示这些信息。

## 说明

- 最终可播放产物通常是 `task.localPath` 或 `task.mp4Path`
- HLS 任务会在分片下载完成后继续转封装成 MP4
- 失败任务的重试在真实业务里应走 `setRefreshUrl`

## Example

示例工程在 `example/lib/` 下，主要包含：

- `pages/init_page.dart`
- `pages/download_detail_page.dart`
- `pages/download_list_page.dart`
- `pages/video_player_page.dart`

示例里演示了：

- 下载器初始化
- 创建任务
- 基于列表的任务管理
- 手动继续、重试、删除
- 本地视频播放
- 相册复制结果处理
