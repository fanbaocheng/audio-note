# AudioNote

> 一个 macOS 桌面应用，把「下载 → 录制 → 转写 → 笔记」做成一条流水线。
>
> Powered by SwiftUI · yt-dlp · Core Audio (AUHAL + BlackHole loopback) · sherpa-onnx (SenseVoice) · ffmpeg

---

## ✨ 它能做什么

- **🎬 从链接直接转写**：粘贴 B 站 / YouTube / 抖音 / 小红书 / 微博 URL → 自动下载音频 → 自动转写成 txt
- **🎙️ 系统音频录制**：通过 BlackHole 等虚拟声卡（loopback 设备）+ Core Audio AUHAL 抓系统输出，可同时混入麦克风；启动录制时自动把系统输出路由到「BlackHole + 耳机」多输出设备，不影响正常听音
- **📝 离线本地转写**：sherpa-onnx + SenseVoice 模型，全程本地推理，不上传任何数据
- **📂 本地文件导入**：mp3 / m4a / wav / mp4 拖进来即转写
- **🔁 断点续转**：转写过程实时把已完成段 flush 到 sidecar，异常中断后可自动从中断处继续，不用每次从头来
- **⏯️ 任务队列**：下载 / 录制 / 转写统一调度，全部支持暂停、继续、重试、取消、置顶
- **📊 双阶段计时**：下载进度 / 下载耗时 / 转写进度 / 转写耗时 / 进行中预估剩余时间，全程可见

---

## 📸 截图

> 主界面分为四个 Tab：录制 / 下载 / 任务 / 笔记 / 设置

（截图待补）

---

## 🏗️ 架构

```
┌────────────────────────────────────────────────────────────┐
│                       SwiftUI UI 层                        │
│   RecordView · DownloadView · TaskQueueView · Transcript   │
└─────────────────────────┬──────────────────────────────────┘
                          │
┌─────────────────────────▼──────────────────────────────────┐
│                    Orchestration 编排层                    │
│   TaskScheduler（并发调度 / 优先级 / 持久化）              │
│   UnifiedPipeline（download → extract → transcribe 串联）  │
└─────────────────────────┬──────────────────────────────────┘
                          │
┌─────────────────────────▼──────────────────────────────────┐
│                       Engine 引擎层                        │
│   DownloadEngine     ── yt-dlp 子进程 + 站点 headers      │
│   AudioCaptureEngine ── Core Audio AUHAL + BlackHole      │
│   AudioProcessingEngine ── ffmpeg 转码 / 混音             │
│   ASRService         ── transcribe.py + sherpa-onnx       │
└─────────────────────────┬──────────────────────────────────┘
                          │
┌─────────────────────────▼──────────────────────────────────┐
│                      外部二进制 / 模型                     │
│   ffmpeg (vendor)  ·  yt-dlp (pip / brew)  ·  Python venv │
│   sherpa-onnx OfflineRecognizer (SenseVoice CTC)          │
└────────────────────────────────────────────────────────────┘
```

详细架构和数据流见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

---

## 📁 目录结构

```
UniAudio/                          # 工程根（GitHub 仓库名 audio-note）
├── Package.swift                  # SwiftPM manifest（macOS 13+，executable target AudioNote）
├── README.md                      # 本文件
├── ARCHITECTURE.md                # 架构 / 数据流 / 关键设计决策
├── DEVELOPMENT.md                 # 开发指南：环境准备 / 构建 / 调试 / 打包
├── LICENSE                        # MIT
├── Sources/
│   ├── App/
│   │   └── AudioNoteApp.swift     # @main 入口、Scene 配置、Settings link
│   ├── Bridge/
│   │   └── BinaryResolver.swift   # 4 级二进制定位：bundle → vendor → PATH → which
│   ├── Core/
│   │   └── DependencyManager.swift# Python venv / pip 包 / ffmpeg / 模型 检测与一键安装
│   ├── Engine/                    # 业务引擎（每个引擎单文件，互不依赖）
│   │   ├── DownloadEngine.swift   # yt-dlp 调度、进度流式解析、错误归一
│   │   ├── AudioCaptureEngine.swift # Core Audio AUHAL 绑 BlackHole loopback + 麦克风混音
│   │   ├── AudioProcessingEngine.swift # ffmpeg 转码、混音、采样率归一
│   │   ├── OutputDeviceRouter.swift # CoreAudio 输出路由
│   │   └── ASRService.swift       # 调用 transcribe.py、sidecar 断点续转
│   ├── Logging/
│   │   └── Logger.swift           # 统一日志（os.Logger + 文件落盘）
│   ├── Models/
│   │   └── Models.swift           # UniTask / TaskStatus / TaskSnapshot 等核心类型
│   ├── Orchestration/
│   │   ├── TaskScheduler.swift    # @MainActor 全局调度器，统一编排所有任务
│   │   └── UnifiedPipeline.swift  # download → extract → transcribe 串联
│   └── UI/
│       ├── DesignTokens.swift     # 颜色 / 间距 / 字号 设计令牌
│       ├── RootView.swift         # NavigationSplitView + sidebar tabs
│       ├── Record/                # 录制视图（波形 / 计时器 / 实时预览）
│       ├── Download/              # 下载视图（URL 输入 + 选项）
│       ├── Queue/                 # 任务队列视图（操作按钮 / 双阶段进度）
│       ├── Transcript/            # 笔记视图（txt 浏览 / 检索）
│       └── Settings/              # 设置（路径 / 模型 / 网络 / 诊断）
├── Tests/                         # 单测（最小骨架）
├── scripts/
│   ├── transcribe.py              # sherpa-onnx 推理脚本，支持 --partial-file 增量 flush
│   └── fetch_vendor.sh            # 首次构建拉取 ffmpeg 静态二进制（48MB，不入 git）
└── vendor/                        # 外部二进制本地缓存（git 忽略）
    └── ffmpeg                     # arm64 静态构建（运行 fetch_vendor.sh 自动获取）
```

---

## 🚀 快速开始

### 前置依赖

| 项 | 版本 | 用途 |
|---|---|---|
| macOS | 13.0+ | SwiftUI / Core Audio |
| BlackHole (2ch) | 0.5+ | 系统音频 loopback（录制系统输出必装；不录制系统音频可不装） |
| Xcode CLT | 15+ | Swift 5.9 toolchain |
| Python | 3.10–3.12 | sherpa-onnx 推理 |
| ffmpeg | 6.0+ | 音视频转码（首次构建自动下载） |

### 编译与运行

```bash
# 克隆
git clone https://github.com/fanbaocheng/audio-note.git
cd audio-note

# 拉 ffmpeg 二进制（48MB，arm64 静态构建）
bash scripts/fetch_vendor.sh

# 如需录制系统音频，安装 BlackHole（虚拟声卡，做 loopback 用）
brew install blackhole-2ch
# 装完后在「音频 MIDI 设置」里创建一个「多输出设备」，勾选 BlackHole 2ch + 你的耳机/扬声器

# 准备 Python venv + sherpa-onnx + yt-dlp
python3 -m venv .venv
source .venv/bin/activate
pip install sherpa-onnx numpy yt-dlp

# 下载 SenseVoice 模型（约 240MB）
# 模型放到 ~/Library/Application Support/AudioNote/models/sense-voice-zh-en-ja-ko-yue-2024-07-17/
# 首次启动 App 会提示下载

# 编译运行（开发态）
swift run -c release
```

### 打包 .app（分发）

```bash
bash scripts/make_app.sh
# 产出 ./AudioNote.app，可直接拷贝到 /Applications/ 或桌面
```

---

## 🔑 关键设计决策

### 1. 下载和转写解耦
下载持久化格式是 **mp3（~150kbps，压缩）**，转写时由 ASRService 临时 ffmpeg 转 16k mono PCM wav 喂给 transcribe.py，转完即删。这样 2.5 小时视频下载下来 ~200MB，而不是无压缩 wav 的 1.85GB。

### 2. 断点续转 sidecar
转写脚本每完成一段（默认 20s 窗口）立即 `_append_partial` → `<basename>.partial.tsv`，open append + flush + `os.fsync(fileno)` 强制刷盘。静音段也写空 text 占位。Swift 启动转写前读 sidecar 拿到 `(priorText, resumeFromSegment)`，把 `--partial-file` + `--resume-from-segment` 透传给脚本，从中断点继续。最终 .txt 写入后清理 sidecar。

### 3. 任务模型统一
下载、录制、导入、转写不分别管理，统一为 `UniTask`，由单一 `TaskScheduler` 调度。每个 task 跟踪 download/transcribe 两个阶段的 `startedAt/finishedAt`，并对外暴露 `elapsedSeconds` / `estimatedRemainingSeconds` 计算字段。

### 4. 文件命名统一
下载音频、录制音频、转写 txt 文件名统一为 `MMDDHHMMSS.xxx`（10 位时间戳，本地时区），便于排序和与笔记关联。导入文件不重命名（保留原始名）。

### 5. 二进制 4 级回退
`BinaryResolver` 按顺序探测：
1. `.app/Contents/Resources/vendor/<bin>`（打包态）
2. `<workspace>/vendor/<bin>`（开发态）
3. `$PATH`
4. `which <bin>`

让开发态和打包态用同一份代码，不需要 #if DEBUG 分支。

---

## 📜 License

MIT © 2026 ryan
