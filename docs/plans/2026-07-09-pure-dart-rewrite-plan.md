# ffmpeg_remux 全新重写实施计划

> **For Claude:** REQUIRED SUB-SKILL: 用 flutter-executing / flutter-subagent-dev 按任务逐个实现。
> 配套设计：[2026-07-09-pure-dart-rewrite-design.md](2026-07-09-pure-dart-rewrite-design.md)

**Goal:** 把 `ffmpeg_remux` 重写为近乎纯 Dart 的离线视频缓存包：Dart 下载 + Dart transmuxer(TS→MP4) + JSON 存储，删除全部 native，做到极致小体积与稳定。

**Architecture:** 务实 SDK 分层（models → store/http → download → remux → api → tests），不套 presentation 层。

**关键前置：** Phase 2 的 transmuxer 实现**必须先拿到作者真实 m3u8 样本**并通过 de-risk 闸门；Phase 1 不依赖样本，可立即开工。

**Dependencies 变化：**
```bash
flutter pub remove sqlite3 sqlite3_flutter_libs
# 保留: dio path path_provider crypto photo_manager
# flutter_hls_parser: 视 m3u8_parser 是否自研决定去留
```

---

## 分支策略

在新分支 `refactor/pure-dart-rewrite` 上进行；`main` 保持现有 0.0.5 可用。新代码写在 `lib/src/` 下，旧 `lib/download/` 与 native 目录**在 Phase 3 才删除**，Phase 1-2 期间共存，便于全链路先跑通并 A/B。

---

# Phase 1 — 骨架 + 下载层 + JSON 存储（不需样本，先跑通端到端）

Phase 1 目标：新架构端到端能下载 mp4 与 hls，**remux 暂时委托现有 native**（走 `ffmpeg_fallback` 适配旧 `FfmpegRemux`），验证下载/刷新/续传/存储/事件全部就绪。

### Task 1.1: 不可变模型与枚举
**Layer:** models
**Files:**
- Create: `lib/src/api/models/task_status.dart`
- Create: `lib/src/api/models/download_task.dart`
- Create: `lib/src/api/models/task_event.dart`
- Create: `lib/src/api/models/download_config.dart`

**规格：**
- `enum TaskStatus { queued, running, remuxing, completed, paused, failed, canceled }`
- `enum SourceKind { mp4, hls }`
- `DownloadTask`：**不可变** + `copyWith`。字段：`taskId, movieId, name, coverImg, url, dir, kind, status, totalBytes, downloadedBytes, mp4Path, albumSaved, albumError, saveToAlbum, error, createdAt`。JSON `toJson/fromJson`（存储用）。**不含** segment 明细（从磁盘推导）。
- `TaskEvent`：`taskId, status, progress(0..1), downloadedBytes, totalBytes, error` —— 对外事件快照，与内部 task 解耦。
- `DownloadConfig`：`maxConcurrency=3, segConcurrency=2, connectTimeout, receiveTimeout, userAgent, refreshMaxRetries, refreshBackoff`。

**Verification:** `flutter analyze lib/src/api/models/` → No issues.
**Commit:** `feat(model): 新增不可变任务模型与配置`

### Task 1.2: 存储接口 + 内存实现
**Layer:** store
**Files:**
- Create: `lib/src/store/task_store.dart`（接口：`Future<List<DownloadTask>> loadAll(); Future<void> upsert(DownloadTask); Future<void> delete(String taskId);`）
- Create: `lib/src/store/memory_task_store.dart`（web/测试用）

**Verification:** `flutter analyze lib/src/store/`
**Commit:** `feat(store): 新增任务存储接口与内存实现`

### Task 1.3: JSON 存储实现（原子写 + 去抖）
**Layer:** store
**Files:**
- Create: `lib/src/store/json_task_store.dart`
- Test: `test/store/json_task_store_test.dart`

**规格：**
- 每任务 `<appDocs>/ffmpeg_remux/tasks/<taskId>.json`。
- `upsert`：写 `<taskId>.json.tmp` 再 `rename`（同盘原子）。进度类高频更新去抖（≥1s 合并一次；状态变更立即写）。
- `loadAll`：扫目录，坏文件跳过不崩。
- 条件导入：`json_task_store_io.dart`（真实）/ web 用 memory。

**Test（Priority 1）：** 写入→读出一致；写一半（tmp 存在、正式文件旧）后 loadAll 仍取旧值不崩；坏 JSON 跳过。
**Commit:** `feat(store): 新增 JSON 原子写任务存储`

### Task 1.4: HTTP 客户端 + URL 刷新器（单飞去重）
**Layer:** download/http
**Files:**
- Create: `lib/src/download/http/http_client.dart`（dio 封装：GET/HEAD、Range、超时、有限重试；识别 404/410 抛特定 `UrlExpiredException`）
- Create: `lib/src/download/http/url_refresher.dart`
- Test: `test/download/url_refresher_test.dart`

**规格（刷新器，稳定性核心）：**
- 注入业务回调 `Future<String> Function(String taskId)`。
- **同一 taskId 的刷新单飞**：并发请求命中 404 时只调一次业务回调，其余等同一个 Future。
- 退避 + 次数上限（`refreshMaxRetries`）；返回空/连续失败 → 抛错交上层置 failed。

**Test（Priority 1）：** mock 回调计数——并发 5 个 404 只触发 1 次回调；超过上限抛错；成功后返回新 URL。
**Commit:** `feat(http): 新增 HTTP 封装与单飞 URL 刷新器`

### Task 1.5: 源类型识别
**Layer:** download
**Files:**
- Create: `lib/src/download/source_detector.dart`（按扩展名 + Content-Type + 内容嗅探 `#EXTM3U` 判定 mp4/hls）

**Commit:** `feat(download): 新增 mp4/hls 源识别`

### Task 1.6: MP4 下载器（Range 断点续传）
**Layer:** download/mp4
**Files:**
- Create: `lib/src/download/mp4/mp4_downloader.dart`
- Test: `test/download/mp4_downloader_test.dart`

**规格：** HEAD 取 `content-length`/`ETag` → 已存在 tmp 且 ETag 未变则 Range 续传 → 流式写 tmp → 完成 rename 为 mp4 → 进度回调。GET/HEAD 遇 404 走刷新器换 URL 续传（ETag 变则从头）。CancelToken 支持 pause/cancel。

**Test：** mock 服务器分段返回 + 中断重连续传字节正确；ETag 变化时重下。
**Commit:** `feat(download): 新增 MP4 Range 断点续传下载器`

### Task 1.7: m3u8 解析
**Layer:** download/hls
**Files:**
- Create: `lib/src/download/hls/m3u8_parser.dart`
- Test: `test/download/m3u8_parser_test.dart`（fixture: master+media, 带 `#EXT-X-KEY`）

**规格：** 解析 master→选流、media→segments（相对/绝对 URI 归一）、`#EXT-X-KEY METHOD=AES-128 URI/IV`。优先自研轻量解析（去掉 `flutter_hls_parser` 依赖以减体积），除非样本出现复杂标签。

**Commit:** `feat(hls): 新增 m3u8 解析`

### Task 1.8: AES-128 解密 + HLS 分片下载器
**Layer:** download/hls
**Files:**
- Create: `lib/src/download/hls/aes_decryptor.dart`（`crypto`/`pointycastle` AES-CBC 整片解密；IV 缺省用 segment index）
- Create: `lib/src/download/hls/hls_downloader.dart`
- Test: `test/download/aes_decryptor_test.dart`（已知向量）

**规格（下载器）：** 并发 `segConcurrency` 下 ts → 整片解密 → 落 `dir/seg_<n>.ts`。**已存在的 seg 文件跳过**（磁盘推导续传）。key/ts 遇 404 走刷新器：刷新入口→重解析 playlist→重映射剩余分片 URL→续传。全部完成产出「分片文件列表」交 remux。

**Test（Priority 1）：** AES 已知向量解密正确；已存在分片跳过；404→刷新→续传只补缺片。
**Commit:** `feat(hls): 新增 AES-128 解密与分片并发下载器`

### Task 1.9: Remux 接口 + ffmpeg 兜底适配
**Layer:** remux
**Files:**
- Create: `lib/src/remux/remuxer.dart`（接口：`Future<RemuxResult> remux({required List<String> segmentFiles, required String outMp4, ProgressCb? onBytes}); void cancel(); Future<void> cleanup(...);`）
- Create: `lib/src/remux/ffmpeg_fallback/ffmpeg_remuxer.dart`（**复用现有 native**：写 local.m3u8 指向已解密分片 → 调旧 `FfmpegRemux`/`FfmpegRemuxIos`）

**说明：** Phase 1 用它让全链路先跑通；Phase 3 换默认实现为 `DartTransmuxer`。
**Commit:** `feat(remux): 新增 remux 接口与 ffmpeg 兜底适配`

### Task 1.10: 下载引擎（调度 + 事件 + 冷启动恢复）
**Layer:** download
**Files:**
- Create: `lib/src/download/task_queue.dart`（`_queue + _active + pump`，`maxConcurrency`）
- Create: `lib/src/download/download_engine.dart`

**规格：** 按 kind 创建 mp4/hls 流程 → hls 完成后调 remuxer → 落 mp4Path。pause/resume/cancel/prioritize。每次状态/进度变更 → `store.upsert` + 抛不可变 `TaskEvent`。冷启动：running/queued/remuxing → paused。

**Commit:** `feat(engine): 新增下载引擎与调度`

### Task 1.11: 相册封装 + 公开门面 API
**Layer:** api / album
**Files:**
- Create: `lib/src/album/album_saver.dart`（photo_manager，返回结构化结果）
- Create: `lib/src/api/download_manager.dart`（门面：`ensureInitialized / setRefreshUrl / enqueue / pause / resume / cancel / delete / copyToAlbum / setMaxConcurrency / taskStream`）
- Modify: `lib/ffmpeg_remux.dart`（barrel 导出新 API）

**规格：** 对外 API 允许重设计（作者已同意全新重写）。自动存相册逻辑保留（不影响 completed，失败记 albumError，防重入）。

**Verification:** `flutter analyze` 全绿；example 接入新 API 手测 mp4+hls 全链路（remux 走 ffmpeg 兜底）。
**Commit:** `feat(api): 新增对外门面 DownloadManager`

### Task 1.12: example 迁移到新 API
**Layer:** integration
**Files:** Modify example 下调用点。
**Verification:** 真机跑通 mp4 + hls 下载、暂停继续、取消、存相册、杀进程恢复。
**Commit:** `refactor(example): 接入新下载 API`

**Phase 1 出口标准：** 新架构端到端可用（remux 仍靠 native）；Task 1.3/1.4/1.6/1.8 单测通过。

---

# Phase 2 — Dart transmuxer 原型（★ 需真实样本，de-risk 闸门）

> **阻塞：需要作者提供 h264 与 h265 各一个真实 m3u8。** 在 `example/` 或独立 dart 脚本里做原型，不进主链路，直到过闸。

### Task 2.1: 抓取样本、建 fixture 语料
拿真实样本下 + 解密出若干 `.ts`，存 `test/fixtures/ts/`（h264 一组、h265 一组、含音频）。用 `ffprobe` 记录期望（时长/帧数/编码/分辨率）作为对照基线。

### Task 2.2: TS demuxer 原型
**Files:** `lib/src/remux/dart_transmuxer/ts_demuxer.dart` + `test/remux/ts_demuxer_test.dart`
188-byte TS packet → 按 PID 收 PES → 还原 ES（视频 Annex-B NAL / 音频 AAC ADTS）+ 每帧 PTS/DTS。对照 ffprobe 断言帧数/时间戳。

### Task 2.3: 码流参数解析
**Files:** `h264_parser.dart`（SPS/PPS→avcC）、`h265_parser.dart`（VPS/SPS/PPS→hvcC）+ 测试。断言生成的 avcC/hvcC 与 ffprobe/ffmpeg 提取的一致。

### Task 2.4: MP4 builder 原型
**Files:** `aac_adts.dart`、`mp4_builder.dart` + 测试。写 ftyp/moov(trak×2, stbl: stts/stss/ctts/stsc/stsz/stco)/mdat。
**实测重点（原型踩坑排序）：**
- **★ `elst` + 全局时间基线**：两轨基线到**单一全局最小时间戳**；空编辑长度=minPTS + media_time=最小 composition 偏移（`media_time=0` 会丢前导帧，且能播但 A/V 静默漂移——本 Task 头号校验点）。
- **ctts** = PTS−DTS，样本按 DTS 存（实测一次即对）。
- `stss` 列全 IDR；`co64` 兜底 >4GB；PTS 33-bit 环绕。
参考会话 scratchpad 里已验证的 `transmux.dart`（695 行，framemd5 全等 ffmpeg）。

### Task 2.5: ★ De-risk 闸门验证
把 fixture 的 ts → 产出 mp4 → 与 ffmpeg `-c copy` 产物做 **framemd5 逐帧比对**（比 PSNR 更诚实——PSNR 受容器时间戳影响，framemd5 只看解码像素）+ `ffprobe` 校验帧数/时长 + 真机播放 h264、h265 各一个。
- **H.264+AAC：已于 2026-07-09 用真实 2.5K B 帧样本过闸（framemd5 全等、PSNR=inf）。** 本 Task 对 h264 只需回归。
- **H.265：待真实样本，重点重验 hvcC(VPS+SPS+PPS) 与 ctts/elst 在 HEVC B 帧流上的正确性。**
- **不通过**（某类流搞不定）→ 记录短板，该类流 remux 长期走 `ffmpeg_fallback`，其余用 Dart；或延后。**不硬写**。

**Commit（分多次）:** `feat(remux): 新增 TS demuxer 原型` / `... h264/h265 参数解析` / `... MP4 builder` 等。

---

# Phase 3 — 切换默认 remux 为 Dart，删除全部 native

> **前提：Phase 2 闸门通过。**

### Task 3.1: DartTransmuxer 实现 Remuxer 接口
`lib/src/remux/dart_transmuxer/dart_transmuxer.dart` 组装 2.2-2.4，实现 `Remuxer`（含 cancel/进度/cleanup）。引擎默认注入它。

### Task 3.2: 全链路回归
example 真机跑 Phase 1 全部手测项 + h264/h265 remux，与 ffmpeg 产物对比一致。

### Task 3.3: 删除 native 与旧代码
- Delete: `android/`（保留空 plugin 或整体移除 native）、`ios/FFmpegMinXC/`、`ios/Classes/*`、`macos/`、`lib/download/`（旧）、`lib/ffmpeg_remux_ios.dart`、`lib/download/local_video_server.dart`、`ffmpeg_fallback/`（若决定不留兜底）。
- Modify: `pubspec.yaml` 去掉 `flutter.plugin` 声明（若不再是 plugin）、去 sqlite。
**Verification:** `flutter analyze` 全绿；example 全链路通过；APK/IPA 体积对比记录。
**Commit:** `refactor: 删除 native 与旧下载实现，remux 纯 Dart 化` / `chore(deps): 移除 sqlite 依赖`

---

# Phase 4 — 测试矩阵与文档收尾

### Task 4.1: 补齐单元测试到设计所列清单
404 状态机、断点续传、store 原子写、demuxer/builder golden 等。`flutter test` 全绿。

### Task 4.2: 更新文档
- Modify: `README.md`（去 ffmpeg/权限说明按需调整）、`TESTING.md`（扩矩阵：h264/h265 remux、大文件、弱网 404 风暴）、`CLAUDE.md`（架构主线改为纯 Dart）、`CHANGELOG.md`（0.1.0）。
**Commit:** `docs: 更新架构与测试文档`

### Task 4.3: 体积基线记录
记录重写前后 release APK/IPA 增量，写入 README。

---

## 风险登记

| 风险 | 缓解 |
|---|---|
| transmuxer 覆盖不全（B 帧/环绕/异常流） | Phase 2 闸门 + 保留 ffmpeg_fallback；fixture 语料覆盖 |
| 样本迟迟不来阻塞 Phase 2 | Phase 1 全程不依赖样本，可先完成 |
| 大文件 Dart 处理内存/卡顿 | mp4_builder 流式写、必要时 Isolate |
| 删 native 后旧接入方不兼容 | 全新重写已同意；example 同步迁移，CHANGELOG 标 breaking |
