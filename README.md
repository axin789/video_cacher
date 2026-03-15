# ffmpeg_remux

A Flutter plugin for:

- downloading `mp4` and `m3u8` sources
- persisting download tasks in SQLite
- refreshing expired URLs through a business callback
- remuxing downloaded HLS content into local `mp4`
- copying the final `mp4` into the system album

This package is designed for apps that need offline video caching with resumable downloads and HLS-to-MP4 output.

## Features

- Supports both `mp4` and `m3u8`
- Automatically detects source type
- Persists tasks locally
- Supports pause / manual resume / delete
- Supports custom URL refresh logic through `setRefreshUrl`
- Supports manual album copy and auto-copy after completion
- Exposes task stream for download list UI

## Platform Support

- Android: supported
- iOS: supported
- macOS: plugin target exists, but the main use case is mobile
- Web: empty implementation for compilation only

## Installation

Add dependency:

```yaml
dependencies:
  ffmpeg_remux: ^0.0.3
```

Then run:

```bash
flutter pub get
```

## Permissions

### Android

Add these permissions in your app `AndroidManifest.xml` when using album copy:

```xml
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32" />
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" android:maxSdkVersion="29" />
```

If your app depends on this plugin module directly, align your example/app project with the plugin Android requirements:

- `compileSdk = 36`
- `ndkVersion = "27.0.12077973"`
- `minSdk = 24`

### iOS

Add these keys to `Info.plist` when using album copy:

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Need to save exported videos into the system album.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Need photo library access to save and view exported videos.</string>
```

## Quick Start

### 1. Initialize

```dart
final mgr = DownloadManager.instance;

mgr.setRefreshUrl((id) async {
  // Query your backend with business id and return the latest playable URL.
  // Example:
  // final result = await api.fetchLatestPlayUrl(id);
  // return result.url;
  throw UnimplementedError();
});

await mgr.ensureInitialized();
await mgr.setMaxConcurrency(3);
```

### 2. Create a task

```dart
final task = await mgr.enqueue(
  id: 'video_1001',
  name: 'Episode 1',
  cover: 'https://example.com/cover.jpg',
  url: 'https://example.com/play.m3u8',
  saveToAlbum: false,
);
```

### 3. Observe task updates

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

### 4. Controls

```dart
mgr.pause(task.taskId);
mgr.resumeById(task.taskId);
await mgr.retryFailedTaskById(task.taskId);
await mgr.deleteTaskById(task.taskId);
```

### 5. Copy to album

```dart
final result = await mgr.copyToAlbumWithResult(task.taskId);
print('ok=${result.ok}, error=${result.error}');
```

Or copy by local path:

```dart
final result = await mgr.copyPathToAlbumWithResult(
  task.mp4Path!,
  title: task.name,
);
```

## API Summary

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

### Task Status

Current task states:

- `queued`
- `running`
- `paused`
- `completed`
- `failed`
- `canceled`
- `postProcessing`

## URL Refresh Contract

`setRefreshUrl` is used in two places:

- when a download hits expired resource errors such as `404` / `410`
- when a failed task is retried manually

The callback receives the current `taskId`:

```dart
Future<String> refreshUrl(String id)
```

Expected behavior:

- return a full playable `mp4` or `m3u8` URL
- return non-empty string
- for HLS, keep playlist structure stable enough for resume

Business example:

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

## Task Behavior

### Same `id` behavior

If the same `id` already exists:

- completed task: treat it as already downloaded
- active/paused task: treat it as already in download list
- failed task: allow retry, and the retry can refresh the internal URL

### App restart behavior

Unfinished tasks are not auto-resumed on cold start.

After app restart:

- unfinished tasks are restored from SQLite
- previous running tasks are converted to `paused`
- user must manually tap `continue` from the download list

## Album Copy Errors

The package exposes detailed album copy result messages, such as:

- `file not exists`
- `file is empty`
- `photo permission denied`
- `saved asset not found`
- `saveVideo exception: ...`

Use `copyToAlbumWithResult` or `copyPathToAlbumWithResult` to surface those messages in UI.

## Notes

- Final playable output is usually `task.localPath` or `task.mp4Path`
- HLS tasks are remuxed to MP4 after segment download completes
- Failed-task retry should go through `setRefreshUrl` in real business integration

## Example

See the example app under `example/lib/`:

- `pages/init_page.dart`
- `pages/download_detail_page.dart`
- `pages/download_list_page.dart`
- `pages/video_player_page.dart`

The example demonstrates:

- downloader initialization
- task creation
- list-based task management
- manual resume / retry / delete
- local video playback
- album copy result handling
