# AudioNote 开发指南

## 环境准备

### 1. 系统要求
- macOS 13.0+（Ventura 及以上，ScreenCaptureKit 要求）
- Apple Silicon 推荐（M1/M2/M3），Intel Mac 需自行替换 ffmpeg 为 x86_64 版本
- Xcode Command Line Tools 15+
- Python 3.10–3.12

### 2. 一次性环境搭建

```bash
# 克隆代码
git clone https://github.com/fanbaocheng/audio-note.git
cd audio-note

# 拉 ffmpeg 静态二进制（48MB，arm64）
bash scripts/fetch_vendor.sh

# 创建 Python venv
python3 -m venv .venv
source .venv/bin/activate

# 安装 Python 依赖
pip install --upgrade pip
pip install sherpa-onnx numpy yt-dlp

# 下载 SenseVoice 模型（约 240MB，HuggingFace）
mkdir -p ~/Library/Application\ Support/AudioNote/models/
cd ~/Library/Application\ Support/AudioNote/models/
git lfs install
git clone https://huggingface.co/k2-fsa/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
```

App 启动时若检测不到模型会弹设置面板提示。

---

## 构建

### 开发态运行（直接 swift run）

```bash
cd audio-note
swift run -c debug         # 带 debug symbol，启动慢但好排查
swift run -c release       # release 优化，启动快
```

适合改代码后快速验证，**不需要重打包 .app**。

### 增量构建

```bash
swift build -c release
# 产物：.build/release/AudioNote
```

构建完后可以拷到 .app bundle 里覆盖：
```bash
cp .build/release/AudioNote ~/Desktop/AudioNote.app/Contents/MacOS/AudioNote
codesign --force --deep --sign - ~/Desktop/AudioNote.app
pkill -x AudioNote && open ~/Desktop/AudioNote.app
```

### 打包完整 .app

```bash
bash scripts/make_app.sh
# 产出 ./AudioNote.app
```

`make_app.sh` 做了什么：
1. `swift build -c release` 编译 binary
2. 创建 `AudioNote.app/Contents/{MacOS,Resources}/` 骨架
3. 写入 `Info.plist`
4. 拷贝 `vendor/ffmpeg` 和 `scripts/transcribe.py` 到 Resources
5. ad-hoc 签名（`codesign --force --deep --sign -`）

---

## 调试

### 日志查看

```bash
# 实时跟随
tail -f ~/Library/Logs/AudioNote/AudioNote-$(date +%Y-%m-%d).log

# 历史排查
ls ~/Library/Logs/AudioNote/
```

### transcribe.py 单独调试

```bash
source .venv/bin/activate

# 全量模式
python3 scripts/transcribe.py /path/to/audio.wav "标题"

# 滑窗模式
python3 scripts/transcribe.py /path/to/audio.wav "" \
  --start-frame 0 --end-frame 320000

# 断点续转
python3 scripts/transcribe.py /path/to/audio.wav "标题" \
  --partial-file /tmp/test.partial.tsv \
  --resume-from-segment 50
```

stdout 每行 JSON：
```json
{"type":"progress","value":42.5}
{"type":"segment","index":7,"text":"...","total":120}
{"type":"result","text":"<全文>"}
{"type":"error","message":"..."}
```

### 任务持久化文件
```bash
cat ~/Library/Application\ Support/AudioNote/tasks.json | jq .
```

清空所有任务历史：
```bash
rm ~/Library/Application\ Support/AudioNote/tasks.json
```

### sidecar 断点文件
```bash
# 转写进行中能看到
ls ~/Downloads/AudioNote/*.partial.tsv
cat ~/Downloads/AudioNote/0626142158.partial.tsv
# 每行 "index<TAB>text"
```

---

## 常见问题

### Q1：模型加载失败 `No such file: model.onnx`
检查模型目录：
```bash
ls ~/Library/Application\ Support/AudioNote/models/sense-voice-zh-en-ja-ko-yue-2024-07-17/
# 应该有 model.int8.onnx 和 tokens.txt
```

### Q2：ffmpeg not found
```bash
# 重新拉
bash scripts/fetch_vendor.sh

# 或用系统 ffmpeg
brew install ffmpeg
# BinaryResolver 会自动回退到 $PATH
```

### Q3：录制时麦克风没声音
- 检查系统设置 → 隐私 → 麦克风 → 给 AudioNote 勾上
- 检查录制 Tab 设置面板里的输入设备选择

### Q4：B 站下载 403 / 412
设置面板 → Cookie 来源选 Chrome / Safari → 重启 App。yt-dlp 会自动读取浏览器 cookie 走带登录态请求。

### Q5：转写卡在某个百分比不动
- 看日志 `~/Library/Logs/AudioNote/`，找 `transcribe.py 非零退出` 关键字
- 查 sidecar：`cat <output>.partial.tsv | wc -l` 看实际写到第几段
- 大概率内存压力（SenseVoice int8 ~1GB 常驻），换 release 构建或重启 App

---

## 代码风格

- Swift 5.9，遵循 [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- UI 使用 SwiftUI + `@ObservableObject`，**不引入 Combine 之外的响应式库**
- 子进程统一走 `Foundation.Process` + `readabilityHandler`，**不引入 Process wrapper 库**
- 日志统一用 `Logger.xxx`（Sources/Logging/Logger.swift），**禁止 print**
- 文件命名 `<功能>.swift`，类型名 PascalCase，方法/属性 camelCase
- 注释优先用中文，公共接口用 `///` doc comment

---

## 测试

```bash
swift test
```

当前测试覆盖率较低，欢迎补 PR。优先级建议：
1. `DownloadEngine.summarizeError` 错误归一表（纯函数好测）
2. `ASRService.readPartialSidecar` sidecar 解析（边界 case：空文件、最后一行无换行、乱序 index）
3. `UniTask.estimatedRemainingSeconds` ETA 计算

---

## 提交 PR

1. Fork 仓库
2. 创建 feature branch：`git checkout -b feature/xxx`
3. 改完跑 `swift build -c release` 确保编译通过
4. 跑 `swift test`（如有相关测试）
5. 提 PR 到 main 分支，描述清楚改动 & 测试方式

提交信息建议格式：
```
<type>: <subject>

<body>

<footer>
```
type 用：`feat` / `fix` / `refactor` / `docs` / `perf` / `chore` / `test`
