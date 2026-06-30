# Changelog

本文档记录 AudioNote 的重要变更。版本号遵循 [Semantic Versioning](https://semver.org/)。

## [0.2.0] - 2026-06-30

### Added
- **录制模式三选一**：录制现在支持三种输入源
  - **系统音频**（保持原有能力，绑定 BlackHole 等环回设备）
  - **麦克风**（直接采集物理麦克风：内置麦/AirPods/USB 麦/iPhone 麦等）
  - **系统音频 + 麦克风混录**（双路 AUHAL 并行采集 → 停止后 ffmpeg `amix` 合并为单文件）
- 新增 `Sources/Engine/AudioMixer.swift`：基于 ffmpeg `volume + amix(normalize=0)` 的两路合并，支持独立增益控制
- 录制设置加入「系统音频音量」「麦克风音量」两个 0-200% 滑块（仅混录模式可见）
- 录制设置加入「保留原始两路音频」开关（默认关，合并后自动清理）
- 录制中心顶部 pill 升级：模式 pill（点击下拉切换）+ 设备 pill（点击展开设备选择 sheet）
- 设备选择 sheet 升级：根据当前模式自动展示对应设备分区（mix 模式同时显示两路）

### Changed
- `AudioCaptureEngine.availableDevices` 拆分为 `availableSystemDevices` / `availableMicDevices`（旧字段保留为兼容别名）
- `AudioCaptureEngine.selectedDevice` 拆分为 `selectedSystemDevice` / `selectedMicDevice`（旧字段保留为兼容别名）
- 设备扫描不再以"loopback 关键字白名单"过滤设备，改为「同时枚举所有 input devices → 按名字关键字归类为系统/麦克风两组」
- 录制文件命名规则：仅系统 `MMDDHHmmss.wav`、仅麦克风 `MMDDHHmmss-mic.wav`、混录最终 `MMDDHHmmss-mix.wav`（保留原始时另存 `-sys.wav` / `-mic.wav`）
- `NSMicrophoneUsageDescription` 文案更新，明确覆盖混录场景

### Notes
- 混录模式下「录制中实时转写预览」只跟随系统音频那一路；停止录制后任务队列会对合并后的完整 wav 重新转写一遍。这是 ffmpeg 后处理方案（C3）的固有特性。
- 静音超时判定依然以主活动路（mix 模式 = 系统音频路）的 RMS 为准，避免环境噪音误触发。

## [0.1.1] - 2026-06-29

### Added
- `scripts/make_app.sh` 一键打包脚本（支持 `release` / `debug` 配置 + `APP_OUT_DIR` 自定义输出目录）
- `Resources/AppIcon.icns` 和 `Resources/Info.plist` 入库（打包流水线所需）

### Docs
- README 重构为「玩法 + App 功能」两段式结构：第一部分讲 AudioNote × AI Agent 联动玩法（3 个场景 + 联动模式 + Skill 模板 + ASR 校验提示），第二部分讲 App 本身能力（截图 + 功能清单 + 文件命名 + 默认目录）；去掉与 ARCHITECTURE/DEVELOPMENT 重复的内容
- 修正 README / DEVELOPMENT / ARCHITECTURE 中路径不一致的问题：
  - 录制默认目录 `~/Documents/AudioNote/Recordings/`（不是 Application Support）
  - 下载默认目录 `~/Documents/AudioNote/Downloads/`（不是 ~/Downloads/AudioNote）
  - 转写 `.txt` 与源音频同目录（不单独放 transcripts/）
  - ASR 模型默认目录 `~/.cache/sherpa-onnx-models/`（不是 Application Support/models/）
  - 模型文件名 `model.int8.onnx`（不是 model.onnx）
- 推荐使用 App 内置「依赖一键安装」流程，手动安装作为高级用法保留
- 移除 ARCHITECTURE §9 已知技术债中过时的「模型下载没有内置下载器」条目

## [0.1.0] - 2026-06-29

首个公开版本（GitHub: [fanbaocheng/audio-note](https://github.com/fanbaocheng/audio-note)）。

### Added
- 转写断点续转：sidecar `<base>.partial.tsv` 每段 flush + fsync，崩溃后自动续转，不再从头开始
- 任务行所有操作按钮全部常驻可见（置顶 / 重试 / 暂停 / 继续 / 取消 / 移除），右键菜单作为冗余入口保留
- 任务行显示双阶段进度：下载进度 + 耗时、转写进度 + 耗时、进行中追加预估剩余时间
- 录制 / 下载 sidebar 顺序调换，默认 Tab 改为录制

### Changed
- 文件命名统一为 `MMDDHHMMSS.xxx`（下载音频 / 录制音频 / 转写 txt）
- 下载持久化格式从 wav 改回 mp3（与 MediaDownloader 对齐），节省约 90% 磁盘空间
- `canPause` 扩展支持 `.recording`，`canRetry` 扩展支持 `.paused`
- ASRService 启动转写时把 `Process` 引用注册到 `task.process`，scheduler.cancel/pause 真正能终止子进程

### Docs
- 修正 README / ARCHITECTURE / DEVELOPMENT 中录制底层的错误描述：实际是 Core Audio AUHAL + BlackHole loopback（完整迁移自 AudioTranscriber.AudioRecorder），不是 ScreenCaptureKit / AVAudioEngine；补充 BlackHole 安装步骤和多输出设备配置说明

### Fixed
- retry 一次产生 3 个重复任务（task 被 insert 两次）→ 改原地复用
- 第二次启动录音时实时转写预览空白 → startRecording 末尾重置 state.totalFrames 等
- 设置面板的 downloadDir/recordingDir 不生效 → UserDefaults key 与引擎统一 + 一次性迁移
- URL 自动补 `https://` 前缀（用户粘贴 `www.xxx.com` 也能下载）
- 下载下来的 wav 文件巨大（2.5h → 1.9GB）→ `--audio-format mp3 --audio-quality 0`，ASRService 内部按需临时转 wav

### Migrated from
- 底层下载引擎照搬 MediaDownloader 的稳定实现（站点 headers / 错误归一 / Cookie 复用）
- 底层转写引擎照搬 AudioTranscriber 的稳定实现（滑窗 / SenseVoice 加载 / 分段策略）
