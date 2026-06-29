# AudioNote 开发指南

## 环境准备

### 1. 系统要求
- macOS 13.0+（Ventura 及以上，SwiftUI / Core Audio）
- Apple Silicon 推荐（M1/M2/M3），Intel Mac 需自行替换 ffmpeg 为 x86_64 版本
- Xcode Command Line Tools 15+
- Python 3.10–3.12
- **BlackHole 2ch**（系统音频录制必装；只用「下载 + 转写」可不装）：`brew install blackhole-2ch`，并在「音频 MIDI 设置」里创建一个多输出设备同时勾选 BlackHole 和你的耳机

### 2. 一次性环境搭建（推荐：用 App 内置依赖面板）

```bash
# 克隆代码
git clone https://github.com/fanbaocheng/audio-note.git
cd audio-note

# 拉 ffmpeg 静态二进制（48MB，arm64，不入 git）
bash scripts/fetch_vendor.sh

# 编译并启动
swift run -c release
```

App 启动后：**设置 → 依赖** → 点「一键安装」，会自动完成：

- 创建 `~/Library/Application Support/AudioNote/python-venv/`（Python venv）
- 安装 `sherpa-onnx` / `numpy` / `yt-dlp`
- 下载 ASR 模型到 `~/.cache/sherpa-onnx-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/`（sherpa-onnx 内置下载器，约 240MB）

### 手动安装依赖

如果偏好手动安装（CI 环境、离线分发等），按下面顺序：

```bash
# Python venv（路径必须是这个，否则 BinaryResolver 找不到）
python3 -m venv ~/Library/Application\ Support/AudioNote/python-venv
source ~/Library/Application\ Support/AudioNote/python-venv/bin/activate
pip install --upgrade pip
pip install sherpa-onnx numpy yt-dlp

# 模型（用 sherpa-onnx 自带下载器 或 git clone）
mkdir -p ~/.cache/sherpa-onnx-models
cd ~/.cache/sherpa-onnx-models
git lfs install
git clone https://huggingface.co/k2-fsa/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17
# 确认结构：
#   ~/.cache/sherpa-onnx-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/
#     ├── model.int8.onnx     ← 实际加载的是 int8 量化版
#     └── tokens.txt
```

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

构建完后可以拷到现有 .app bundle 里热替换（不重打包）：
```bash
cp .build/release/AudioNote ~/Desktop/AudioNote.app/Contents/MacOS/AudioNote
codesign --force --deep --sign - ~/Desktop/AudioNote.app
pkill -x AudioNote && open ~/Desktop/AudioNote.app
```

### 打包完整 .app

```bash
bash scripts/make_app.sh                          # release，输出 build/AudioNote.app
bash scripts/make_app.sh debug                    # debug 配置
APP_OUT_DIR=~/Desktop bash scripts/make_app.sh    # 自定义输出目录
```

`make_app.sh` 做了什么：
1. 前置检查 `Resources/{Info.plist,AppIcon.icns}` 和 `vendor/ffmpeg` 在不在
2. `swift build -c <CONFIG>` 编译 binary
3. 创建 `AudioNote.app/Contents/{MacOS,Resources/scripts,Resources/vendor}/` 骨架
4. 拷 binary 到 MacOS/
5. 拷 `Resources/Info.plist`、`Resources/AppIcon.icns`、`scripts/transcribe.py`、`vendor/ffmpeg` 到对应位置
6. ad-hoc 签名（`codesign --force --deep --sign -`）
7. 报告产物大小和路径

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
sidecar 文件与源音频同目录。下载来源在 `~/Documents/AudioNote/Downloads/`，录制来源在 `~/Documents/AudioNote/Recordings/`：

```bash
# 转写进行中能看到
ls ~/Documents/AudioNote/Downloads/*.partial.tsv
cat ~/Documents/AudioNote/Downloads/0626142158.partial.tsv
# 每行 "index<TAB>text"
```

---

## 常见问题

### Q1：模型加载失败 `No such file: model.int8.onnx`
检查模型目录（**默认在 `~/.cache/sherpa-onnx-models/`，不是 Application Support**）：
```bash
ls ~/.cache/sherpa-onnx-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/
# 应该有 model.int8.onnx 和 tokens.txt
```

如果目录不存在或文件缺失，打开 App → 设置 → 依赖 → 一键安装让 sherpa-onnx 内置下载器重新拉。

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
