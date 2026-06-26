# Changelog

本文档记录 AudioNote 的重要变更。版本号遵循 [Semantic Versioning](https://semver.org/)。

## [Unreleased]

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

### Fixed
- retry 一次产生 3 个重复任务（task 被 insert 两次）→ 改原地复用
- 第二次启动录音时实时转写预览空白 → startRecording 末尾重置 state.totalFrames 等
- 设置面板的 downloadDir/recordingDir 不生效 → UserDefaults key 与引擎统一 + 一次性迁移
- URL 自动补 `https://` 前缀（用户粘贴 `www.xxx.com` 也能下载）
- 下载下来的 wav 文件巨大（2.5h → 1.9GB）→ `--audio-format mp3 --audio-quality 0`，ASRService 内部按需临时转 wav

### Migrated from
- 底层下载引擎照搬 MediaDownloader 的稳定实现（站点 headers / 错误归一 / Cookie 复用）
- 底层转写引擎照搬 AudioTranscriber 的稳定实现（滑窗 / SenseVoice 加载 / 分段策略）
