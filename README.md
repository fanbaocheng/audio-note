# AudioNote

> 一个 macOS 桌面应用，把「下载 → 录制 → 转写 → 笔记」做成一条流水线。
>
> Powered by SwiftUI · yt-dlp · Core Audio (AUHAL + BlackHole loopback) · sherpa-onnx (SenseVoice) · ffmpeg

---

## 💡 第一部分：玩法 —— AudioNote × AI Agent 能解决什么问题

AudioNote 本身只做一件事：把声音变成文本。但当它和你身边的 AI Agent（[WorkBuddy](https://www.codebuddy.cn/workbuddy) / Claude Code / Cursor 等）串起来之后，它会变成一个**「时间放大器」**——把你以前必须**坐在那里实时听**的内容，变成可以**异步处理、随时检索、一键分享**的结构化知识。

### 🎯 场景 1：培训/分享直播时间冲突，让 app 替你"在场"

行业大牛的分享/培训直播经常和会议、跟孩子时间撞车，错过就只能等回放（甚至没有回放）。
- 在电脑上挂着直播页面，打开 AudioNote 录制系统音频（走 BlackHole loopback 抓内放，**直播平台不需要任何配合**）
- 直播结束后 AudioNote 自动转写出 txt
- Agent 检测到新文件 → 调用「直播分享总结」Skill → 输出**核心观点 + 金句 + 行动建议** 三段式笔记
- 你晚上下班回来直接读 5 分钟笔记，等于看完 2 小时直播

**收益**：把 2 小时的线性直播压缩成 5 分钟的可检索笔记，且全程不需要你坐在屏幕前。

### 🎯 场景 2：长播客/访谈视频，从 2 小时到 3 分钟摘要

B 站 / YouTube 上有大量 1–3 小时的优质访谈、播客、Podcast，听完成本高，但你又不想错过。
- 在 B 站找到访谈视频页 → 复制 URL 粘到 AudioNote 的下载框
- AudioNote 自动剥离音轨（**不下视频**，省 90% 空间）→ 转写
- Agent 调用「访谈摘要」Skill → 输出**人物观点 + 金句卡片 + 重要时间戳** + （可选）转成微博/朋友圈分享文案
- 你只看输出的 3 分钟摘要，命中兴趣点了再去看原视频对应段落

**收益**：信息消费效率提升 20–40 倍，且避免"以为听完了其实只记住开头"的伪学习。

### 🎯 场景 3：联动日历，会议自动录音 → 自动出纪要 → 自动同步到个人站点

把 AudioNote 接到 Apple 日历 / Outlook / 飞书日历的 Agent 上：
- 会议日程时间到 → Agent 自动调起 AudioNote 开始录制（系统音频 + 麦克风混音）
- 会议结束（日历事件 endTime 或检测到长时间静音）→ 自动停止录制并转写
- Agent 调用「会议纪要」Skill → 输出**议题 / 决议 / Action Items（带 owner + due date）/ 待跟进问题** 结构化纪要
- 纪要自动发布到**个人 OA Pages 站点 / Notion / 公司 wiki**，生成永久链接
- Agent 把链接通过企微/邮件**自动发给所有与会者**，附带一句"如有补充欢迎在评论区/wiki 上修订"

**收益**：会议结束的瞬间纪要就已经躺在会议群里了，告别"会后没人整理纪要 → 三天后所有人都忘了讨论了什么 → 决议无法落地"的死循环。

### 🔌 怎么把 AudioNote 接到 Agent 上

AudioNote 只做最稳的事 —— **把"声音"变成"文本"**，并把 txt 文件落到一个固定目录。**总结、提炼、整理** 这件事交给上层 Agent，让 AudioNote 成为 Agent 工作流的「音频入口」。

**联动模式**：在 Agent 平台配一个**定时任务**（cron / launchd / Agent 平台的 schedule），周期性扫描 AudioNote 的输出目录（默认 `~/Documents/AudioNote/Downloads/` 和 `~/Documents/AudioNote/Recordings/`，转写 `.txt` 与源音频同目录），发现新增 `.txt` 就触发一个**总结 Skill**，自动产出结构化笔记。

**按场景写不同的总结 Skill**：

| 场景 | 输入 | Skill 产出 |
|---|---|---|
| 会议录音 | 会议系统音频 + 麦克风混音 | **会议纪要**：议题/决定/行动项（owner+deadline）/风险/待跟进 |
| 直播课程 / 技术分享 | B 站直播回放 URL / 录屏系统音频 | **课程笔记**：知识点大纲 / 重点代码片段 / 引用资料 / 习题 |
| 播客 / 人物访谈 | 播客 RSS / YouTube URL | **人物观点 + 金句卡片**：嘉宾立场 / 论据链 / 可引用金句 |
| 自言自语备忘 | 麦克风录制 | **TODO 提取**：把碎碎念里的待办、想法、灵感分类落到 PKM |

**ASR 准确率补偿（重要）**：

AudioNote 用的是 sherpa-onnx + SenseVoice 本地小模型，**离线、隐私 OK，但识别准确率约 85–92%**，专有名词、英文术语、人名、数字常有错。在 Skill 的 prompt 里**必须加事实校验约束**，否则错误会被 LLM 总结放大。建议至少包含这几条：

1. **不要直接复述 ASR 文本**：先做事实纠错——根据上下文推断专有名词、人名、技术术语的正确写法，可疑处标 `[?]` 而非编造
2. **挂载领域知识库**：把你常用的项目代号、同事英文名、技术栈词表、行业黑话喂给 LLM（WorkBuddy 的 PKM / Cursor 的 codebase / Claude 的 Project knowledge 都行），强制 Skill 在总结时引用这份知识库做校对
3. **数字 / 日期 / URL 二次校验**：金额、版本号、时间点这类强结构信息，Skill 要单独抽出来标记"低置信度，请人工确认"
4. **保留可追溯性**：总结里关键论断附带原文片段（行号/时间戳），方便回溯——这样即使 LLM 误读，也能快速发现

**示例：WorkBuddy 上配置定时扫描任务**（一句话指令）：

> *"每 10 分钟扫描一次 `~/Documents/AudioNote/Downloads/` 和 `~/Documents/AudioNote/Recordings/` ，对今天新增的 `.txt` 文件调用 `meeting-minutes` skill 生成纪要并归档到 PKM；处理过的文件在文件名追加 `.processed` 后缀避免重复处理"*

WorkBuddy 会自动把这条变成一个 RRULE 自动化跑起来。其它 Agent 平台同理，核心是「扫目录 → 去重 → 调 Skill → 归档」四步。

### 关键洞察：AudioNote 不"做总结"，但它让"总结"成为可能

行业里 ASR + LLM 一体的产品（飞书妙记、腾讯会议智能纪要）很好用，但有两个问题：① 数据上云，敏感内容不能用；② 总结模板写死，没法按你自己的语境和知识库定制。**AudioNote 走另一条路**：

- **声音→文本** 这一段 100% 本地（sherpa-onnx 离线推理），不上云
- **文本→结构化笔记** 这一段交给你**自己的 Agent + 自己的 Skill + 自己的知识库**，你想怎么总结就怎么总结
- 中间用一个**固定的目录**（文件名 `MMDDHHMMSS.txt`）做约定，谁都能接入

把这条管道接起来，你就有了一个**完全私有、完全可定制、随用随调** 的"声音→知识"流水线。

---

## 🎯 第二部分：App 本身能做什么

### 截图

| 录制 | 下载 |
|---|---|
| ![录制 Tab](docs/screenshots/record.png) | ![下载 Tab](docs/screenshots/download.png) |

**依赖自检面板**：设置 → 依赖 一键检查 ffmpeg / Python / yt-dlp / sherpa-onnx / ASR 模型 是否齐全，缺什么点一键安装。

![依赖自检](docs/screenshots/dependencies.png)

### 核心能力

- **🎬 从链接直接转写**：粘贴 B 站 / YouTube / 抖音 / 小红书 / 微博 URL → 自动下载音频 → 自动转写成 txt
- **🎙️ 系统音频录制**：通过 BlackHole 等虚拟声卡（loopback 设备）+ Core Audio AUHAL 抓系统输出，可同时混入麦克风；启动录制时自动把系统输出路由到「BlackHole + 耳机」多输出设备，不影响正常听音
- **📝 离线本地转写**：sherpa-onnx + SenseVoice 模型，全程本地推理，不上传任何数据
- **📂 本地文件导入**：mp3 / m4a / wav / mp4 拖进来即转写
- **🔁 断点续转**：转写过程实时把已完成段 flush 到 sidecar，异常中断后可自动从中断处继续，不用每次从头来
- **⏯️ 任务队列**：下载 / 录制 / 转写统一调度，全部支持暂停、继续、重试、取消、置顶
- **📊 双阶段计时**：下载进度 / 下载耗时 / 转写进度 / 转写耗时 / 进行中预估剩余时间，全程可见

### 文件命名约定

- 下载音频 / 录制音频 / 转写 txt 的文件名统一为 **`MMDDHHMMSS.xxx`**（10 位时间戳，本地时区），便于排序和与笔记关联
- 导入文件保留原始名，不重命名
- 转写 `.txt` 与源音频**同目录同名**，方便 Agent 联动

### 默认目录（可在「设置」里改）

| 类型 | 路径 |
|---|---|
| 下载音频 | `~/Documents/AudioNote/Downloads/` |
| 录制音频 | `~/Documents/AudioNote/Recordings/` |
| 转写 `.txt` | 与源音频同目录 |
| ASR 模型 | `~/.cache/sherpa-onnx-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/` |
| Python venv | `~/Library/Application Support/AudioNote/python-venv/` |

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

详细分层、数据流、关键设计决策（mp3 持久化 / sidecar 断点 / 任务模型 / 二进制 4 级回退）见 **[ARCHITECTURE.md](./ARCHITECTURE.md)**。

---

## 📁 目录结构

```
AudioNote/                         # 工程根（GitHub 仓库名 audio-note）
├── Package.swift                  # SwiftPM manifest（macOS 13+，executable target AudioNote）
├── README.md                      # 本文件
├── ARCHITECTURE.md                # 架构 / 数据流 / 关键设计决策
├── DEVELOPMENT.md                 # 开发指南：环境准备 / 构建 / 调试 / 打包
├── CHANGELOG.md                   # 版本变更记录
├── LICENSE                        # MIT
├── Sources/
│   ├── App/                       # @main 入口、Scene 配置
│   ├── Bridge/                    # BinaryResolver 4 级二进制定位
│   ├── Core/                      # DependencyManager 依赖自检
│   ├── Engine/                    # 业务引擎（Download / AudioCapture / AudioProcessing / ASR）
│   ├── Logging/                   # 统一日志
│   ├── Models/                    # UniTask / TaskStatus / TaskSnapshot 核心类型
│   ├── Orchestration/             # TaskScheduler + UnifiedPipeline
│   └── UI/                        # SwiftUI 视图（Record / Download / Queue / Transcript / Settings）
├── Tests/                         # 单测（最小骨架）
├── scripts/
│   ├── transcribe.py              # sherpa-onnx 推理脚本（支持 --partial-file 增量 flush）
│   ├── fetch_vendor.sh            # 拉 ffmpeg 静态二进制（arm64，~22MB，不入 git）
│   └── make_app.sh                # 一键打包 .app
├── Resources/                     # AppIcon.icns / Info.plist（打包用）
└── vendor/                        # 外部二进制本地缓存（git 忽略，运行 fetch_vendor.sh 获取）
```

---

## 🚀 快速开始

```bash
# 1. 克隆
git clone https://github.com/fanbaocheng/audio-note.git
cd audio-note

# 2. 拉 ffmpeg 二进制
bash scripts/fetch_vendor.sh

# 3. 如需录制系统音频，安装 BlackHole（虚拟声卡）
#    优先用 brew（注意必须带 --cask），若提示 "No Cask with this name exists"
#    先 brew update 一次再试；还不行就用官方 .pkg 直装（见下方）
brew update && brew install --cask blackhole-2ch
# 装完后必须重启一次 macOS！然后在「音频 MIDI 设置」里创建「多输出设备」，
# 勾选 BlackHole 2ch + 你的耳机/扬声器
#
# brew 走不通的兜底方案（官方 .pkg，无需 brew）：
#   https://existential.audio/blackhole/  填邮箱后下载 BlackHole2ch.v0.7.0.pkg 双击安装

# 4. 编译运行
swift run -c release
```

**首次启动**：打开 App → 进入「设置 → 依赖」面板，按提示**一键安装**剩余依赖（Python venv / pip 包 / ASR 模型，约 240MB，装在用户目录下不污染系统）。

**打包 `.app` 分发**：

```bash
bash scripts/make_app.sh
# 产出 build/AudioNote.app，可拷贝到 /Applications/ 或桌面
```

更详细的环境准备、构建、调试、FAQ 见 **[DEVELOPMENT.md](./DEVELOPMENT.md)**。

---

## 📜 License

MIT © 2026 ryan
