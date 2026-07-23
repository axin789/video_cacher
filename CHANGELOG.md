## 0.3.0

真机实测「处理中」阶段 98% 的时间花在 AES 解密上，本版把这一步交给系统加密库。

### 行为变更（升级注意）

- **本包重新成为 Flutter plugin**（0.2.x 是纯 Dart package）。新增的原生代码
  只有一个 Kotlin 文件和一个 Swift 文件，**不捆绑任何二进制**——没有 `.so`、
  没有 `.xcframework`、没有 vendored framework，只调用系统 API，包体积影响可忽略。
- **升级后必须完整重建**（`flutter clean` 后重新安装），热重载/增量安装不会
  带上新插件；没带上也不会坏，只是继续走纯 Dart 慢路径。
- `environment.flutter` 提升到 `>=3.7.0`（背景 isolate 用平台通道所需的
  `BackgroundIsolateBinaryMessenger` 自 3.7 起提供）。

### 性能

- **HLS AES-128 解密改用系统硬件 AES**：Android 走 `javax.crypto.Cipher`
  （Conscrypt → BoringSSL），iOS 走 `CommonCrypto` 的 `CCCrypt`，两者都吃
  ARMv8 的 AES 指令。真机上纯 Dart 实测约 1MB/s（已 3 路 isolate 并行），
  系统库是 500-2000MB/s 量级。433MB 加密视频的实测基线为
  `phases: decryptWait=400425ms demux=6524ms build=1866ms`（解密占 98%），
  预期整个「处理中」阶段从约 409s 降到 10s 级，解密不再是瓶颈。
- 解密不再为每片 spawn 子 isolate：系统库自带原生后台线程（Android 固定线程池、
  iOS 后台 `DispatchQueue`），平台线程与 UI 线程都不阻塞；前瞻预取流水线与
  内存上界维持不变。

### 兜底与正确性

- **平台不可用时自动退回纯 Dart**（pointycastle），语义完全不变：无原生实现的
  平台（macOS/桌面）、`flutter test`、拿不到 `RootIsolateToken` 的场景都走兜底。
- 主 isolate 在 remux 前用一个固定的 openssl 向量做**一次性能力探测**（同时校验
  PKCS7 去填充语义一致），结果缓存到进程结束；探测不过就整轮纯 Dart，不会为每片
  白付一次通道往返。单片解密失败只退回这一片，不永久关掉硬件路径。
- 产物**逐字节一致**：纯 Dart 路径的 golden sha256 未变
  （`bb987871e8b68c367c3b00149dfe7d69ee9a315e2f3323c2c01040ab0535ffd7`），
  另新增真机 integration test（`example/integration_test/platform_aes_test.dart`）
  在 0B~1MB 各种长度上逐字节比对两条路径，并覆盖背景 isolate 的通道路径。
- 日志新增解密后端标记，真机一眼可见走的是哪条路：
  `[video_cacher.crypto] AES backend: platform(hardware)` 或
  `... dart(software fallback)`；原有的 `phases:` 耗时行保留，收益可直接量化。

## 0.2.1

真机接入实测（yc169）暴露的四个问题的修复版。

- **修复「任务一启动就失败」**：401/403 纳入 URL 过期刷新触发（部分 CDN 用 403
  表示 token 过期），状态码集合可通过 `DownloadConfig.refreshStatusCodes` 配置。
- **修复下载慢**：AES 解密从下载路径后置到 remux 阶段——下载只落加密分片
  （`seg_<n>.ts.enc`），解密在 remux worker isolate 内逐片进行，下载恢复纯网络
  速度；旧版已解密分片可无缝续用。
- **根治大文件 OOM**：转封装改为两遍全流式（样本先落 ES 临时文件，再流式合成
  mp4），内存峰值与视频大小解耦（312MB 输入实测增量 347MB → 53MB），GB 级视频
  可下。产物字节与旧实现完全一致（sha256 校验）。
- **缩短加密视频「处理中」阶段耗时**：worker 内加密分片改为前瞻并行预解密
  （读盘 + AES 放子 isolate，与转封装流水线重叠，前瞻 2 片），299MB 加密输入
  实测 4.9s → 2.2s（约 2.2×，Mac；真机单核 AES 更慢、收益更大）。内存上界为
  「当前片 + 至多 2 个前瞻片，且在飞字节不超过 24MB」，大分片源不会因前瞻抬高
  峰值；产物字节不变（sha256 校验）。
- **修复偶发 504/5xx 直接判定任务失败**（三层韧性）：
  ① HTTP 层瞬时故障重试放宽为「3 次、1s 起指数退避」（可配
  `DownloadConfig.transientMaxRetries` / `transientBackoff`）；
  ② HLS 新增**分片级重试**：单个分片 5xx 再等 2s/4s/8s 重试，源站过载需要更长
  冷却；③ 分片级也用尽时**冷却 10s 后刷新签名 URL 重试**（新签名常路由到健康
  边缘节点），已下分片全部保留。此前一个分片 504 会直接判死整个任务。
- transmux 日志新增阶段耗时 `phases: decryptWait=…ms demux=…ms build=…ms`，
  便于定位「处理中」阶段的真实瓶颈。
- `DownloadConfig` 新增 `headers`（自定义请求头，如 CDN 防盗链 Referer）。
- pointycastle 版本约束放宽至 `>=3.7.3`，兼容宿主工程锁定的旧版本。

## 0.2.0

### 修复

- 转封装流兼容性：ADTS 音频帧跨 PES 包拼接、视频访问单元续包合并、PSI(PAT/PMT)
  跨 TS 包积累、截断 PES 防护——此前会丢帧或产出坏 mp4 的真实流现可正确转封装。
- 时间戳与盒健壮性：PTS/DTS 33 位环绕展开、pts<dts 非法时间戳钳制（DTS 平移）、
  全关键帧流省略空 stss、音频 tkhd duration 时基单位修正。
- HLS 播放列表按 UTF-8（含 BOM）解码，修复非 ASCII 播放列表的幽灵分片与
  URL 双重编码。
- mp4 断点续传语义修正：资源 ETag 随任务持久化，If-Range 携带旧 etag（弱 etag
  不发），服务端内容变更自动从 0 重下，416 + 总长未知可自动恢复。
- mp4 下载流中途瞬断按 Range 有限重试（≤2 次），不再直接 failed。
- 源类型误判自愈：mp4 任务嗅探到 m3u8 内容自动纠正为 HLS 并同轮完成；
  源嗅探只拉取前 64 字节。
- URL 刷新后 HLS 变体按带宽锁定，续传不再混入其他码率。
- 多音轨流优选 AAC 音轨，不再因选中不支持的音轨而失败。
- 引擎：清理非活跃任务的暂停/取消意图残留（内存小泄漏）。

### 性能

- mdat 流式落盘：remux 内存峰值降至约 1.1~2.3 倍输入（100MB 输入 5.83x→2.27x，
  200MB 1.64x）。
- remux 移入独立 isolate：主线程零冻结，逐分片真实进度，取消经 Isolate.kill
  立即生效。
- HLS AES-128 解密每片走 Isolate.run，不再阻塞 UI。
- 进度事件按任务节流（100ms 窗口），高频分块不再刷爆事件流。

### 行为变更（升级注意）

- **进度字段量纲分阶段**：`downloadedBytes`/`totalBytes` 在 mp4 下载阶段为字节、
  HLS 下载阶段为分片数、remuxing 阶段为 remux 输入字节（第二段 0..1）；
  **completed 终态统一回填为最终 mp4 文件字节数**。依赖旧语义的 UI 需检查。
- **不支持的播放列表特性从静默产坏数据变为明确失败**：SAMPLE-AES 等非 AES-128
  加密、key 轮换、EXT-X-MAP(fMP4)、EXT-X-BYTERANGE、EXT-X-DISCONTINUITY
  在下载任何分片前即 failed（`UnsupportedPlaylistException`）。
- **h265 等不支持编码 fail-fast**：remux 在首个含 PMT 的分片即报错并列出全部
  stream_type，不再空跑完全部分片再失败。
- `Remuxer.onProgress` 语义变更：回调参数为已喂入的累计输入字节（此前无真实进度）。
- `DownloadTask` 新增 `etag` 字段（JSON 持久化向后兼容，旧记录读出为 null）。

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
