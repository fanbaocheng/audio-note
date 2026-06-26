# AudioNote 架构文档

> 本文档描述 AudioNote 的核心架构、关键数据流和重要技术决策。

---

## 1. 分层结构

```
┌──────────────────────────────────────────────────────┐
│ UI 层  (SwiftUI / @ObservableObject)                 │
│   ↓ 仅通过 ObservableObject 单向消费                │
├──────────────────────────────────────────────────────┤
│ Orchestration 层  (TaskScheduler / UnifiedPipeline) │
│   ↓ 持有所有 task，调度 Engine                       │
├──────────────────────────────────────────────────────┤
│ Engine 层  (DownloadEngine / ASRService / ...)      │
│   ↓ 调用外部进程，返回结果                          │
├──────────────────────────────────────────────────────┤
│ Bridge 层  (BinaryResolver / Process 子进程封装)    │
└──────────────────────────────────────────────────────┘
```

**核心约束**：
- UI 不直接调 Engine，必须经 Orchestration
- Engine 不持有 UI 状态，结果通过 task 回写
- 跨层通信只允许两种方式：① `@Published` 状态变更 ② 异步 await 返回值

---

## 2. 核心数据模型

### 2.1 UniTask
```swift
final class UniTask: ObservableObject, Identifiable {
    let id: UUID
    @Published var inputType: InputType   // .url / .recording / .file
    @Published var status: TaskStatus
    @Published var progress: Double

    // 双阶段计时
    @Published var downloadStartedAt: Date?
    @Published var downloadFinishedAt: Date?
    @Published var transcribeStartedAt: Date?
    @Published var transcribeFinishedAt: Date?

    // 断点续转 sidecar
    @Published var transcribePartialURL: URL?
    @Published var transcribeCompletedSegments: Int = 0

    // 持有子进程引用（让 scheduler.cancel/pause 能 terminate）
    weak var process: Process?

    // 派生计算
    func downloadElapsedSeconds(now: Date = .now) -> TimeInterval? { ... }
    func transcribeElapsedSeconds(now: Date = .now) -> TimeInterval? { ... }
    func estimatedRemainingSeconds(now: Date = .now) -> TimeInterval? { ... }
}
```

### 2.2 TaskStatus
```swift
enum TaskStatus {
    case pending
    case resolving           // 解析元信息
    case downloading
    case downloadingPaused
    case downloaded          // 下载完，等待转写
    case recording
    case extracting          // ffmpeg 转码中
    case transcribing
    case transcribingPaused
    case completed
    case failed(String)
    case cancelled
    case skippedTranscribe

    var canPause: Bool   { /* downloading/transcribing/recording */ }
    var canResume: Bool  { /* downloadingPaused/transcribingPaused */ }
    var canRetry: Bool   { /* failed/cancelled */ }
    var canCancel: Bool  { /* 任何非终态 */ }
    var canRemove: Bool  { /* 终态 */ }
}
```

---

## 3. 关键数据流

### 3.1 URL → 转写笔记的完整流水线

```
[用户粘贴 URL]
   ↓
[DownloadView.onSubmit]
   ↓ scheduler.enqueue(.url(s))
[TaskScheduler 创建 UniTask, status=.pending]
   ↓ 调度循环检测到空闲槽位
[UnifiedPipeline.execute(task)]
   ↓
[Stage 1: DownloadEngine]
   ├─ yt-dlp --print 拿元信息 → 填 title/uploader
   ├─ yt-dlp -f bestaudio/best -x --audio-format mp3 流式下载
   ├─ readabilityHandler 解析 progress / speed / eta
   └─ task.downloadFinishedAt = now, task.localFileURL = <mp3>
   ↓
[Stage 2: ASRService.transcribeBatch]
   ├─ 检测输入非 wav → convertToWav() 临时 16k mono PCM
   ├─ 读 sidecar <base>.partial.tsv 拿 (priorText, resumeFromSegment)
   ├─ python3 transcribe.py <wav> <title>
   │       --partial-file <base>.partial.tsv
   │       --resume-from-segment N
   ├─ 子进程 stdout 每行 JSON：
   │   {"type":"progress","value":42.5}
   │   {"type":"segment","index":7,"text":"...","total":120}
   │   {"type":"result","text":"<全文>"}
   │   {"type":"error","message":"..."}
   ├─ 段事件 → task.transcribeCompletedSegments++
   └─ 合并 priorText + newText 写 <base>.txt, 删 sidecar
   ↓
[task.status = .completed, finishedAt = now]
   ↓
[UI 监听 @Published 自动刷新；Tab 红点 -1]
```

### 3.2 断点续转细节

**transcribe.py 关键代码**：
```python
def _append_partial(partial_file, seg_idx, text):
    with open(partial_file, "a", encoding="utf-8") as pf:
        pf.write(f"{seg_idx}\t{text}\n")
        pf.flush()
        os.fsync(pf.fileno())   # 强制 flush 到磁盘

# 主循环
for i in range(resume_idx, total_chunks):
    chunk = read_chunk(i)
    if is_silent(chunk):
        _append_partial(partial_file, i, "")        # 静音也写占位
        continue
    text = recognizer.decode(chunk).text
    _append_partial(partial_file, i, text)          # 每段立即刷盘
    log_json("segment", index=i, text=text, total=total_chunks)
    log_json("progress", value=(i+1) / total_chunks * 100)
```

**ASRService.transcribeBatch 关键代码**：
```swift
let partialURL = outDir.appendingPathComponent("\(baseName).partial.tsv")
task?.transcribePartialURL = partialURL

let (priorText, resumeFrom) = readPartialSidecar(partialURL)

let newText = await runFullTranscription(
    audioURL: wavURL,
    title: title,
    partialFile: partialURL,
    resumeFromSegment: resumeFrom,
    task: task
)

let finalText = priorText + newText
try finalText.write(to: txtURL, atomically: true, encoding: .utf8)
try? FileManager.default.removeItem(at: partialURL)   // 清理 sidecar
```

**故障恢复场景**：
- 转写到第 50 段时 App 崩溃 → sidecar 已有 0..49 段
- 重启 App → 用户点「重试」→ readPartialSidecar 返回 (priorText, 50)
- 脚本 `--resume-from-segment 50` → 跳过前 50 段直接从 50 开始
- 50..119 段写入 sidecar → 合并所有段 → 写最终 txt

---

## 4. 录制实现

### 4.1 ScreenCaptureKit + AVAudioEngine 混音

```
┌──────────────────┐         ┌──────────────────┐
│ ScreenCaptureKit │         │  AVAudioEngine   │
│  (系统输出音频)  │         │   (麦克风输入)   │
└────────┬─────────┘         └─────────┬────────┘
         │                             │
         │  AVAudioPCMBuffer           │  AVAudioPCMBuffer
         │  48kHz stereo               │  设备原生采样率
         │                             │
         └──────────┬──────────────────┘
                    ▼
         ┌──────────────────────┐
         │  AudioMixer (sample- │
         │  rate convert + sum) │
         └──────────┬───────────┘
                    ▼
         ┌──────────────────────┐
         │  AVAudioFile 写盘    │
         │  16kHz mono PCM wav  │
         └──────────────────────┘
```

文件名固定 `MMDDHHMMSS.wav`，存到 `~/Library/Application Support/AudioNote/recordings/`（可在设置改）。

### 4.2 实时转写预览
录制中每隔 N 秒（默认 5s）取最近 K 秒滑窗喂给 transcribe.py 的 `--start-frame/--end-frame` 模式，结果实时显示在录制 Tab 的预览面板。

---

## 5. 任务调度

### 5.1 调度循环
```swift
@MainActor final class TaskScheduler: ObservableObject {
    @Published var allTasks: [UniTask] = []
    private var activeCount: Int = 0
    let maxConcurrent: Int = 2

    func tick() async {
        while activeCount < maxConcurrent,
              let next = nextRunnableTask() {
            activeCount += 1
            Task {
                await UnifiedPipeline.execute(next, scheduler: self)
                activeCount -= 1
                await tick()
            }
        }
    }

    func nextRunnableTask() -> UniTask? {
        allTasks
            .filter { $0.status == .pending }
            .sorted { $0.priority > $1.priority }   // 置顶 = priority 10
            .first
    }
}
```

### 5.2 暂停/取消语义
- **pause**：`task.process?.terminate()` + `status = .downloadingPaused / .transcribingPaused`
- **resume**：`status = .pending` 重入调度（转写靠 sidecar 自动续）
- **cancel**：`task.process?.terminate()` + `status = .cancelled`
- **retry**：原地复用 task（不 insert 新 task，避免重复任务 bug），清空 progress/err，置 .pending

---

## 6. 二进制定位（BinaryResolver）

```swift
enum BinaryResolver {
    static func ffmpegURL() -> URL? {
        // 1. .app/Contents/Resources/vendor/ffmpeg
        if let url = bundleVendor("ffmpeg") { return url }
        // 2. <workspace>/vendor/ffmpeg
        if let url = workspaceVendor("ffmpeg") { return url }
        // 3. $PATH
        if let url = pathLookup("ffmpeg") { return url }
        // 4. /usr/bin/which
        if let url = whichLookup("ffmpeg") { return url }
        return nil
    }
    // python3 / yt-dlp / transcribe.py 同样的 4 级回退
}
```

让开发态（直接跑 `swift run`）和打包态（双击 .app）共用同一份代码，无需 `#if DEBUG`。

---

## 7. 持久化

| 数据 | 存储 | 格式 |
|---|---|---|
| 任务快照 | `~/Library/Application Support/AudioNote/tasks.json` | JSON encoded `[TaskSnapshot]` |
| 转写 sidecar | 与输出 txt 同目录 `<base>.partial.tsv` | TSV `index\ttext\n`，转写完成后自动删 |
| 设置 | `UserDefaults` | downloadDir / recordingDir / maxConcurrent / cookieSource ... |
| 日志 | `~/Library/Logs/AudioNote/AudioNote-YYYY-MM-DD.log` | 行式 |
| 录制音频 | `~/Library/Application Support/AudioNote/recordings/` | wav |
| 下载音频 | `~/Downloads/AudioNote/` | mp3 |
| 笔记 txt | 与音频同目录 | utf-8 文本 |

---

## 8. 重要技术决策记录（ADR）

### ADR-001：为什么下载持久化用 mp3 而不是 wav
- **背景**：早期版本 `yt-dlp --audio-format wav`，2.5h 视频下来 1.85GB（PCM 1536kbps）
- **决策**：改 `--audio-format mp3 --audio-quality 0`，转写时由 ASRService 临时转 wav
- **理由**：mp3 ~150kbps，2.5h ~200MB，节省 90% 磁盘；用户多数情况不需要保留无损版本
- **代价**：转写前多一步 ffmpeg 转码（~5s/小时音频，可接受）

### ADR-002：为什么转写用 Python 子进程而不是 Swift binding
- **背景**：sherpa-onnx 有 Swift 头文件，理论上可直接链接
- **决策**：保留 Python 子进程，stdout 流式 JSON 通信
- **理由**：
  1. 复用 AudioTranscriber 已经验证稳定的脚本
  2. 模型加载、滑窗、断点续转都在 Python 实现成熟
  3. Swift binding 引入额外编译复杂度（libsherpa-onnx.dylib 打包）
- **代价**：增加 Python 依赖；用户需要 venv 准备

### ADR-003：为什么文件名统一 MMDDHHMMSS
- **背景**：早期下载用 `<date> - <title> [<id>].mp3`，录制用 `<date>_<time>_system_audio.wav`，命名不一致
- **决策**：统一 `MMDDHHMMSS.xxx`，所有类型对齐
- **理由**：①按文件名排序 = 按时间排序 ②文件名短便于搜索 ③转写 txt 自动跟随 basename
- **例外**：用户导入的文件不重命名（保留原始名 + ext）

### ADR-004：断点续转选 sidecar 而不是直接写最终 txt
- **决策**：用单独的 `<base>.partial.tsv` 累积，全部完成后才合并写 `<base>.txt`
- **理由**：
  1. 最终 txt 应该「要么完整要么不存在」，避免用户打开看到半截
  2. sidecar 每行 `index\ttext` 自带元信息（哪段、是否静音），便于 resume
  3. 合并写 txt 是原子操作（atomically: true）
- **代价**：磁盘多一个临时文件（转写完成自动删）

---

## 9. 已知技术债

- [ ] `TaskSnapshot` 持久化时未编码新增的 `downloadStartedAt/transcribeStartedAt` 字段，重启后这些时间会丢
- [ ] `runWindowTranscription`（录制实时预览滑窗）没接 sidecar，断点续转只对离线转写生效
- [ ] 模型下载没有内置下载器，需要用户手动 git clone hf 仓库
- [ ] 没有自动更新机制（Sparkle 等）
- [ ] ffmpeg 仅 arm64，Intel Mac 不可用
- [ ] 没有 i18n，全中文硬编码
