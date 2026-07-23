# 测试检查清单

接入真实测试数据后，可以按下面清单验证。

## A. 基础环境

- [ ] Flutter 版本为 3.27.4
- [ ] `flutter pub get` 执行成功
- [ ] `flutter analyze` 执行成功（主包和 example 都通过）

## B. MP4 流程

- [ ] 使用 `id/name/url` 创建 MP4 下载任务
- [ ] 下载过程中进度会按已下载字节更新
- [ ] 暂停后可以继续
- [ ] 取消后任务状态变为 canceled
- [ ] 下载完成后 `localPath/mp4Path` 有效

## C. HLS 流程

- [ ] 创建 m3u8 下载任务
- [ ] 分片下载进度正常更新
- [ ] 纯 Dart 转封装正常执行并输出最终 mp4
- [ ] 最终任务状态为 completed
- [ ] AES-128 加密流解密后可正常播放

### C1 h265 预期失败（首分片 fail-fast）

- [ ] 创建 h265(HEVC) 的 m3u8 任务
- [ ] 转封装阶段在**首个含 PMT 的分片**即失败，不空跑完全部分片
- [ ] 任务状态为 failed，error 含 `UnsupportedStreamException` 且列出 PMT 全部 stream_type（属预期行为）

### C2 不支持特性的播放列表（下载前即报错）

- [ ] 分别构造含 SAMPLE-AES、key 轮换（多个不同 EXT-X-KEY）、EXT-X-MAP(fMP4)、
      EXT-X-BYTERANGE、EXT-X-DISCONTINUITY 的 m3u8 任务
- [ ] 任务在**下载任何分片（含 key）前**立即 failed
- [ ] error 为 `UnsupportedPlaylistException` 且指明具体不支持的特性

### C3 remuxing 阶段进度

- [ ] HLS 任务进入 remuxing 后，进度条从 0 重新起步并持续前进（第二段 0..1）
- [ ] completed 后 downloadedBytes/totalBytes 回填为最终 mp4 文件字节数

## D. URL 过期恢复

### D1 MP4
- [ ] MP4 地址在 HEAD 阶段过期（404/410）后，回调刷新地址并继续下载
- [ ] MP4 地址在 GET 流阶段过期后，回调刷新地址并继续下载

### D2 HLS
- [ ] 入口 m3u8 返回 404/410 后，可以刷新并继续
- [ ] key 地址返回 404/410 后，可以刷新并继续
- [ ] ts 地址返回 404/410 后，可以刷新并继续

### D3 弱网中断（mp4）

- [ ] mp4 下载中制造网络瞬断（如切飞行模式几秒再恢复、弱网工具限速断流）
- [ ] 流中断后按 Range 自动续拉（有限次重试），无需手动 resume
- [ ] 重试耗尽仍失败时任务落 failed，手动 resume 可从断点继续

## E. remux 过程中的取消语义

- [ ] 启动 HLS remux
- [ ] remux 过程中执行取消
- [ ] 取消**立即生效**（remux isolate 被强停，进度即刻停止，不等当前分片喂完）
- [ ] 任务状态变为 canceled
- [ ] 不产出最终 mp4
- [ ] 临时 remux 文件会被清理

## F. 复制到相册

- [ ] `copyToAlbum(taskId)` 成功路径正常
- [ ] `copyPathToAlbum(path)` 成功路径正常
- [ ] 权限拒绝时能明确返回失败原因

## G. 持久化恢复

- [ ] 下载过程中杀掉 app 后重新打开
- [ ] 任务能从 JSON 存储恢复
- [ ] 未完成任务在重启后变成 `paused`
- [ ] 用户点击继续后，任务能从断点恢复

---

## 测试数据模板

验证时可以整理成下面这样的表：

| caseId | type | id | initialUrl | expected |
|---|---|---|---|---|
| 1 | mp4 | v1001 | ... | 正常完成 |
| 2 | m3u8 | v1002 | ... | 正常完成 |
| 3 | mp4-expire | v1003 | ... | 刷新后继续 |
| 4 | hls-ts-expire | v1004 | ... | 刷新后继续 |
| 5 | hls-cancel-remux | v1005 | ... | 已取消且没有最终 mp4 |
| 6 | hls-h265 | v1006 | ... | failed，error 含 UnsupportedStreamException |
