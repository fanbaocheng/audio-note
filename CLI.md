# AudioNote CLI 参考手册

> `audio-note` 是 AudioNote 的命令行工具，与 GUI App **共享同一份数据、配置和任务库**。
> 设计目标：让 AI Agent（WorkBuddy / Claude Code / Cursor / 脚本）能通过 JSON Lines 协议接入 AudioNote 的录制、转写、下载能力。
>
> **WorkBuddy 用户**：本仓库已内置 `audio-note-cli` Skill（`.workbuddy/skills/audio-note-cli/`），
> 安装到你的 WorkBuddy 后即可让 Agent 直接调用本 CLI 的全部能力。详见 [第 8 节 Agent 集成示例](#8-agent-集成示例)。

---

## 目录

- [1. 安装](#1-安装)
- [2. 架构概述](#2-架构概述)
- [3. 全局 flag](#3-全局-flag)
- [4. JSON Lines 协议](#4-json-lines-协议)
- [5. 退出码](#5-退出码)
- [6. 单实例互斥锁](#6-单实例互斥锁)
- [7. 命令参考](#7-命令参考)
  - [7.1 device — 音频设备管理](#71-device--音频设备管理)
  - [7.2 settings — 读写应用配置](#72-settings--读写应用配置)
  - [7.3 library — 录音库与任务管理](#73-library--录音库与任务管理)
  - [7.4 record — 录制音频](#74-record--录制音频)
  - [7.5 transcribe — 转写音频/视频](#75-transcribe--转写音视频)
  - [7.6 download — 下载远程音视频](#76-download--下载远程音视频)
- [8. Agent 集成示例](#8-agent-集成示例)

---

## 1. 安装

```bash
# 从源码构建
cd AudioNote
swift build -c release
sudo cp .build/arm64-apple-macosx/release/audio-note /usr/local/bin/

# 或一键打包（同时产出 GUI .app 和 CLI 二进制）
bash scripts/make_app.sh
# CLI 二进制位于 build/audio-note
sudo cp build/audio-note /usr/local/bin/
```

验证安装：

```bash
$ audio-note --version
0.3.0
```

---

## 2. 架构概述

CLI 和 GUI 共享同一套核心库（`AudioNoteCore`），所有数据落同一个地方：

```
┌──────────────────────────────────────────────────────┐
│                    AudioNoteCore                      │
│  (AppDefaults · AudioCaptureEngine · DownloadEngine  │
│   ASRService · TaskScheduler · SingleInstanceLock)   │
└──────────────┬────────────────┬──────────────────────┘
               │                │
    ┌──────────▼──────┐  ┌──────▼──────────┐
    │  AudioNoteApp   │  │  AudioNoteCLI   │
    │  (GUI .app)     │  │  (audio-note)   │
    └─────────────────┘  └─────────────────┘
               │                │
               ▼                ▼
    UserDefaults suite: com.ryanfan.audionote
    ~/Library/Application Support/AudioNote/
    ~/Documents/AudioNote/Recordings/
    ~/Documents/AudioNote/Downloads/
```

**关键约定**：
- 配置通过 `AppDefaults.shared`（UserDefaults suite `com.ryanfan.audionote`）共享，CLI 设的 settings GUI 能看到，反之亦然
- 录制音频存入 `recording.dir`，下载音频存入 `downloads.dir`，转写 txt 与源音频同目录
- 文件名统一为 `MMDDHHMMSS.xxx`（本地时区时间戳）

---

## 3. 全局 flag

以下 flag 对所有子命令生效：

| Flag | 简写 | 说明 |
|------|------|------|
| `--json` | — | stdout 输出 JSON Lines（结构化，便于 agent 解析）；所有日志和进度只走 stderr |
| `--verbose` | `-v` | 详细日志输出到 stderr |
| `--quiet` | `-q` | 静默模式（除错误外不输出） |
| `--force-takeover` | — | 互斥锁被占用时，通过 SIGTERM 通知对方退出并接管（仅 record / transcribe / download 支持） |

**Human 模式（默认）**：stdout = 人类可读文本（表格/进度条），stderr = 日志/错误。

**Agent 模式（`--json`）**：stdout = 100% JSON Lines（每行一个完整 JSON 对象，`fflush` 立即刷盘），stderr = 静默（除非加 `-v`）。

---

## 4. JSON Lines 协议

`--json` 模式下，stdout 每一行是一个完整的 JSON 对象，格式为 `{"type": "<event_type>", ...}`。每行后 `fflush(stdout)`，Agent 可以按行读取实时响应。

### 4.1 事件类型

| type | 说明 | 出现时机 | 负载字段 |
|------|------|---------|---------|
| `info` | 信息提示 | 任意时机 | `message` |
| `row` | 数据行（列表输出） | 表格类子命令 | 子命令特定字段 |
| `done` | 完成信号 | 表格/操作结束时 | `count`（整数，row 总数）或操作特定字段 |
| `result` | 操作结果 | 操作成功完成 | 操作特定的结果字段 |
| `progress` | 进度更新 | 长时间操作进行中 | `elapsed_sec`, `rms_level`, `silence_seconds` 等 |
| `event` | 状态事件 | 操作生命周期节点 | `name`（事件名）+ 事件特定字段 |
| `error` | 错误 | 操作失败时 | `code`（错误码字符串）, `message`, `details`（可选） |

### 4.2 row 事件（表格类输出）

`device list`、`settings list`、`library list` 等子命令输出 `row` 事件流，最后一条为 `done`：

```
{"id":87,"kind":"system","name":"BlackHole 2ch","selected":true,"type":"row","uid":"BlackHole2ch_UID"}
{"id":117,"kind":"mic","name":"MacBook Pro麦克风","selected":false,"type":"row","uid":"BuiltInMicrophoneDevice"}
{"count":2,"type":"done"}
```

### 4.3 progress 事件（长时间操作）

`record` 命令每 0.5s 输出一条 progress：

```
{"elapsed_sec":5,"rms_level":0.0234,"silence_seconds":0,"type":"progress"}
{"elapsed_sec":6,"rms_level":0.0187,"silence_seconds":1,"type":"progress"}
```

### 4.4 event 事件（操作生命周期）

```
{"name":"started","type":"event","mode":"systemAudio","system_device":"BlackHole 2ch","mic_device":"","silence_timeout_min":5,"duration_limit_sec":0}
{"name":"silence_timeout","type":"event","seconds":300}
```

### 4.5 result 事件

```
{"file":"/Users/.../Recordings/0701091234.wav","size_bytes":1204224,"duration_sec":45,"mode":"systemAudio","stop_reason":"signal","queued_for_transcribe":true,"type":"result"}
```

### 4.6 error 事件

```
{"code":"BUSY","details":{"holder":"AudioNoteGui","mode":"gui","pid":"12345"},"message":"AudioNote 已在运行：GUI 实例 (pid 12345)，请先关闭。可加 --force-takeover 强制接管。","type":"error"}
```

### 4.7 Agent 消费注意

- **顺序**：正常操作的事件流是 `event → [progress|row...] → result → done`
- **错误中断**：任意时刻都可能出现 `error` 事件（后跟非零退出码）
- **`row` 结束**：表格类输出以 `done` 结尾，`done.count` 等于 `row` 总数
- **`progress` 终止**：`progress` 流以 `result` 或 `error` 结束
- **编码**：所有字段值均为 JSON 原生类型（string/number/bool/null），无特殊转义

---

## 5. 退出码

遵循 BSD sysexits 约定：

| 退出码 | 常量 | 含义 | 典型场景 |
|--------|------|------|---------|
| `0` | EX_OK | 成功 | 正常完成 |
| `64` | EX_USAGE | 命令行用法错误 | 参数格式错误、无效 flag 值 |
| `66` | EX_NOINPUT | 输入文件/设备不存在 | 传入不存在的文件路径、未知设备 ID |
| `70` | EX_SOFTWARE | 内部软件错误 | 启动录制失败、转写状态异常 |
| `74` | EX_IOERR | 输入/输出错误 | 下载失败、文件写入失败、录音过短未生成文件 |
| `75` | EX_TEMPFAIL | 暂时不可用 | 互斥锁被 GUI 占用（`code: "BUSY"`）、锁文件错误 |

**Agent 集成提示**：
- 退出码 `75` → 提示用户关闭 GUI 或加 `--force-takeover`
- 退出码 `64` → 参数问题，修正参数重试
- 退出码 `74` → IO 问题（磁盘满 / 权限 / 网络），不可重试（需人工介入）
- 退出码 `70` → 程序 bug，请上报

---

## 6. 单实例互斥锁

CLI 和 GUI 同时只能运行一个实例，通过 `flock(LOCK_EX|LOCK_NB) + PID 心跳` 实现。

### 锁定行为

| 场景 | 行为 |
|------|------|
| CLI 启动、GUI 未运行 | 获取锁，开始执行 |
| CLI 启动、GUI 运行中 | 退出码 75，stderr/stdout 输出 BUSY 错误 |
| 加 `--force-takeover` | CLI 向 GUI 发送 SIGTERM，等待最多 5s 退出，然后获取锁 |
| GUI 启动、CLI 运行中 | GUI 弹窗提示"CLI 实例正在运行" |
| 进程异常退出 | PID 心跳探测（`kill(pid, 0)`）自动识别死锁，清理后重新获取 |

### 哪些命令需要锁

| 需要锁 | 不需要锁 |
|--------|---------|
| `record` | `device list` / `device refresh` / `device default get` |
| `transcribe` | `settings list` / `settings get` |
| `download` | `library list` / `library show` |
| `settings set` / `settings reset` | |

---

## 7. 命令参考

### 7.1 device — 音频设备管理

```
audio-note device <subcommand>

子命令：
  list      列出所有音频输入设备（默认）
  refresh   重新扫描音频设备
  default   查看 / 设置默认设备
```

#### 7.1.1 device list

```
audio-note device list [--kind system|mic|all] [--json] [-v|-q]
```

列出所有音频输入设备。设备按 kind 分为两类：
- `system`：系统音频设备（如 BlackHole 虚拟声卡、Multi-Output Device）
- `mic`：麦克风设备（内置麦、AirPods、USB 麦等）

**选项**：
| Flag | 说明 |
|------|------|
| `--kind system` | 只看系统音频设备 |
| `--kind mic` | 只看麦克风设备 |
| `--kind all` | 所有设备（默认） |
| `--type <kind>` | `--kind` 的兼容别名 |

**JSON Lines 字段（row）**：
```json
{"id": <number>, "kind": "system|mic", "name": "<字符串>", "selected": <bool>, "type": "row", "uid": "<设备 UID>"}
```

**示例**：
```bash
# Human 模式（表格）
$ audio-note device list
ID   KIND    NAME                           SELECTED
──   ────    ────                           ────────
87   system  BlackHole 2ch                  ✓
82   mic     MacBook Pro麦克风               ✓
117  mic     "iPhone 99 Pro"的麦克风

# Agent 模式（JSON Lines）
$ audio-note device list --json --kind system
{"id":87,"kind":"system","name":"BlackHole 2ch","selected":true,"type":"row","uid":"BlackHole2ch_UID"}
{"count":1,"type":"done"}
```

#### 7.1.2 device refresh

```
audio-note device refresh [--json] [-v|-q]
```

重新扫描系统中的音频设备，更新缓存。

**JSON Lines**：无 row 输出，仅 `result` + `done`。

```bash
$ audio-note device refresh --json
{"device_count":4,"type":"result"}
{"type":"done"}
```

#### 7.1.3 device default get

```
audio-note device default get [--json] [-v|-q]
```

查看当前选中的默认设备。

**JSON Lines（result）**：
```json
{"system": {"id": 87, "uid": "BlackHole2ch_UID", "name": "BlackHole 2ch"}, "mic": {"id": 82, "uid": "BuiltInMicrophoneDevice", "name": "MacBook Pro麦克风"}, "type": "result"}
```

#### 7.1.4 device default set

```
audio-note device default set --kind system|mic --device <id|uid|name> [--json] [-v|-q]
```

设置默认设备。设置的设备会持久化到 UserDefaults，GUI/CLI 共享。

**选项**：
| Flag | 必需 | 说明 |
|------|------|------|
| `--kind system\|mic` | 是 | 设备类型 |
| `--device <id\|uid\|name>` | 是 | 设备标识：数字 ID、UID 字符串、或设备名 |

**示例**：
```bash
# 按设备名设置
$ audio-note device default set --kind system --device "BlackHole 2ch"

# 按 UID 设置（GUI/CLI 重启后不丢失）
$ audio-note device default set --kind mic --device "BuiltInMicrophoneDevice"

# Agent：获取列表 → 解析 id → 用 id 设置
$ audio-note device list --json --kind mic | grep '"type":"row"' | jq -r '"\(.id) \(.name)"'
82 MacBook Pro麦克风
```

**错误**：
- 设备不存在 → 退出码 66，`code: "NOT_FOUND"`

---

### 7.2 settings — 读写应用配置

```
audio-note settings <subcommand>

子命令：
  list      列出所有可配置项及当前值（默认）
  get       读取单个配置项
  set       写入单个配置项
  reset     重置某个配置项（或全部）
```

#### 7.2.1 配置项一览

| Key | 类型 | 默认值 | 说明 |
|-----|------|--------|------|
| `downloads.cookie_source` | string | `""` | yt-dlp cookie 来源：`none`/`chrome`/`safari`/`firefox`/`edge`/`brave` |
| `downloads.dir` | string | `""` | 下载目录（空 = 用默认路径） |
| `downloads.max_concurrent` | string | `""` | 下载并发数 |
| `recording.dir` | string | `""` | 录音保存目录（空 = 用默认路径） |
| `recording.mode` | string | `""` | 录制模式：`system`/`mic`/`mix` |
| `recording.silence_timeout_min` | string | `""` | 静音自动停止阈值（分钟） |
| `recording.mix.system_gain` | string | `""` | 混录系统音频增益（0..2） |
| `recording.mix.mic_gain` | string | `""` | 混录麦克风增益（0..2） |
| `recording.mix.keep_originals` | string | `""` | 混录后是否保留原始文件 |

#### 7.2.2 settings list

```
audio-note settings list [--json] [-v|-q]
```

列出所有配置项。

**JSON Lines 字段（row）**：
```json
{"description": "<说明>", "key": "<配置 key>", "type": "row", "value": "<当前值/空字符串>"}
```

**示例**：
```bash
$ audio-note settings list --json
{"description":"下载目录","key":"downloads.dir","type":"row","value":""}
{"description":"录音保存目录","key":"recording.dir","type":"row","value":""}
{"description":"录制模式 system/mic/mix","key":"recording.mode","type":"row","value":""}
{"count":9,"type":"done"}
```

#### 7.2.3 settings get

```
audio-note settings get <key> [--raw] [--json] [-v|-q]
```

读取单个配置项。

**选项**：
| Flag | 说明 |
|------|------|
| `--raw` | 只输出裸值（无 `key = ` 前缀），便于 `$(audio-note settings get ... --raw)` 直接取用 |

**JSON Lines（result）**：
```json
{"key":"recording.dir","type":"result","value":"/Users/ryan/Recordings"}
```

**Human 模式**：
```bash
$ audio-note settings get recording.dir
recording.dir = /Users/ryan/Recordings

$ audio-note settings get recording.dir --raw
/Users/ryan/Recordings
```

**错误**：
- 不存在的 key → 退出码 64，`code: "USAGE"`

#### 7.2.4 settings set

```
audio-note settings set <key> <value> [--json] [-v|-q]
```

写入单个配置项。写入值会持久化到 UserDefaults，GUI 立即可见（下次启动生效）。

**示例**：
```bash
# 设置录音目录
$ audio-note settings set recording.dir ~/Recordings

# 设置录制模式
$ audio-note settings set recording.mode mix

# 设置静音停止阈值
$ audio-note settings set recording.silence_timeout_min 10

# Agent 模式
$ audio-note settings set recording.dir /tmp/audio --json
{"key":"recording.dir","type":"result","value":"/tmp/audio"}
```

**错误**：
- 不存在的 key → 退出码 64
- 值类型不合法 → 退出码 64（如 `recording.mix.system_gain` 设为非数字）

#### 7.2.5 settings reset

```
audio-note settings reset [<key>] [--all] [--json] [-v|-q]
```

重置配置项为默认值。

- `audio-note settings reset recording.dir` — 重置单项
- `audio-note settings reset --all` — 重置所有 audio-note 已知项

---

### 7.3 library — 录音库与任务管理

```
audio-note library <subcommand>

子命令：
  list      列出所有录音条目与任务（默认）
  show      查看单条任务详情
  export    把任务音频或转写复制到指定路径
  delete    删除任务（可选连带文件）
```

#### 7.3.1 library list

```
audio-note library list [--status all|completed|failed|pending|running] [--json] [-v|-q]
```

列出所有已持久化任务 + 已扫描的孤立音频文件。

**JSON Lines 字段（row）**：
```json
{"audio": "<音频文件路径>", "chars": <数字>, "created": "<ISO 8601>", "id": "<任务ID或'(file)'>", "status": "<状态描述或'(无任务)'>", "title": "<标题>", "transcript": "<转写文件路径/空>", "type": "row"}
```

- `id` 为 `"(file)"` 表示该条目是扫描到的孤立音频文件，尚未创建任务
- `chars` 为 0 表示尚未转写或转写失败

**示例**：
```bash
$ audio-note library list --status completed --json
{"audio":".../0630181337.wav","chars":15234,"created":"2026-06-30T10:13:37Z","id":"a1b2c3d4","status":"已完成","title":"0630181337.wav","transcript":".../0630181337.txt","type":"row"}
{"count":1,"type":"done"}
```

#### 7.3.2 library show

```
audio-note library show <id> [--json] [-v|-q]
```

查看单条任务详情。`<id>` 为任务 ID 前缀（至少 4 字符）。

**JSON Lines（result）**：
```json
{"audio":"<路径>","chars":<数字>,"created":"<ISO 8601>","id":"<完整 ID>","input_type":"<url/recording/file>","status":"<状态>","title":"<标题>","transcript":"<路径/空>","type":"result"}
```

**错误**：
- ID 前缀未匹配到任务 → 退出码 66

#### 7.3.3 library export

```
audio-note library export <id> [--kind audio|transcript] [--to <path>] [--json] [-v|-q]
```

把任务的音频或转写文件复制到指定路径。

**选项**：
| Flag | 默认值 | 说明 |
|------|--------|------|
| `--kind audio\|transcript` | `transcript` | 导出类型 |
| `--to <path>` | stdout（transcript）/ 当前目录（audio） | 目标路径。若为目录则在目录下自动 append 源文件名 |

**示例**：
```bash
# 导出转写到指定文件
$ audio-note library export a1b2 --to ~/Desktop/meeting.txt

# 导出音频到指定目录（自动用源文件名）
$ audio-note library export a1b2 --kind audio --to ~/Desktop/

# Agent: 导出转写文本到 stdout
$ audio-note library export a1b2 --json | jq -r '.text'
```

#### 7.3.4 library delete

```
audio-note library delete <id> [--with-files] [--json] [-v|-q]
```

删除任务记录。

| Flag | 说明 |
|------|------|
| （无） | 仅删除任务记录，不删文件 |
| `--with-files` | 同时删除音频与转写文件 |

**警告**：`--with-files` 是**不可逆**操作，删除的音频/转写文件无法恢复。

---

### 7.4 record — 录制音频

```
audio-note record [--mode system|mic|mix] [--device <id|uid|name>] [--device-mic <id|uid|name>]
                   [--duration <秒>] [--silence-timeout-min <分钟>]
                   [--auto-enqueue|--no-auto-enqueue] [--force-takeover]
                   [--json] [-v|-q]
```

录制系统音频 / 麦克风 / 混合 → wav。**按 Ctrl+C 停止**。

录制前需确保：
1. 若录制系统音频：已安装 BlackHole 虚拟声卡并配置多输出设备
2. 若录制麦克风：系统已授权麦克风权限
3. 录制音频保存到 `recording.dir`（默认 `~/Documents/AudioNote/Recordings/`）

**选项**：
| Flag | 默认值 | 说明 |
|------|--------|------|
| `--mode system\|mic\|mix` | settings 中的 `recording.mode` | 录制模式 |
| `--device <id\|uid\|name>` | settings 中的默认设备 | 系统音频设备 |
| `--device-mic <id\|uid\|name>` | settings 中的默认设备 | 麦克风设备 |
| `--duration <秒>` | `0`（无上限） | 录制最大时长 |
| `--silence-timeout-min <分钟>` | settings 或 5 分钟 | 静音自动停止阈值 |
| `--auto-enqueue` | 默认开启 | 录完自动加入 GUI 任务队列 |
| `--no-auto-enqueue` | — | 录完不加入队列 |
| `--force-takeover` | — | 强制接管 GUI 占用的锁 |

**JSON Lines 事件流**：
```
{"name":"started","type":"event","mode":"systemAudio","system_device":"BlackHole 2ch","mic_device":"","silence_timeout_min":5,"duration_limit_sec":0}
{"elapsed_sec":1,"rms_level":0.0234,"silence_seconds":0,"type":"progress"}
{"elapsed_sec":2,"rms_level":0.0187,"silence_seconds":1,"type":"progress"}
  ...（每 0.5s 一条，直到停止）
{"file":"/Users/.../Recordings/0701091234.wav","size_bytes":1204224,"duration_sec":45,"mode":"systemAudio","stop_reason":"signal","queued_for_transcribe":true,"type":"result"}
{"file":"/Users/.../Recordings/0701091234.wav","type":"done"}
```

**停止方式**：
| 方式 | stop_reason | 退出码 |
|------|-------------|--------|
| Ctrl+C（SIGINT） | `signal` | 0（优雅停止，正常输出 result） |
| `--force-takeover` 触发 SIGTERM | `signal` | 0（同上） |
| 静音超时 | `silence_timeout` | 0 |
| 达到 `--duration` 上限 | `duration_limit` | 0 |

**示例**：
```bash
# 录制系统音频（最简用法）
$ audio-note record
● 录制中 [系统音频] — 按 Ctrl+C 停止
⏺  01:23  [████████████······] RMS 0.08
^C
✓ 录制完成：~/Documents/AudioNote/Recordings/0701091234.wav（01:23，1204KB）

# 混录系统音频 + 麦克风，静音 10 分钟后自动停止
$ audio-note record --mode mix --silence-timeout-min 10

# Agent: 后台录制，流式读进度（需配合 --json）
$ audio-note record --json --mode mix --duration 600 | while IFS= read -r line; do
    type=$(echo "$line" | jq -r '.type')
    if [ "$type" = "result" ]; then
        file=$(echo "$line" | jq -r '.file')
        echo "录制完成: $file"
    fi
done
```

**错误**：
- 未选择设备 → 退出码 66，`code: "NO_DEVICE"`
- 启动录制失败 → 退出码 70，`code: "RECORD_FAILED"`
- 录音过短未生成文件 → 退出码 74，`code: "RECORD_EMPTY"`
- GUI 占用 → 退出码 75，`code: "BUSY"`

---

### 7.5 transcribe — 转写音频/视频

```
audio-note transcribe <input> [--output <目录>] [--download-mode audio|video] [--force-takeover] [--json] [-v|-q]
```

转写本地音频/视频文件，或**自动识别 URL** 走下载+转写全链路。

- `<input>` 为本地路径 → 直接转写（支持 wav/mp3/m4a/mp4 等）
- `<input>` 为 URL → 先下载音频，再转写

转写引擎：sherpa-onnx + SenseVoice 模型，100% 本地离线推理。

**选项**：
| Flag | 默认值 | 说明 |
|------|--------|------|
| `--output <目录>` | 输入文件同目录 | 输出目录 |
| `--download-mode audio\|video` | `audio` | URL 模式下的下载模式 |
| `--force-takeover` | — | 强制接管 GUI 占用的锁 |

**JSON Lines 事件流（本地文件）**：
```
{"name":"start","type":"event","mode":"file","file":"/Users/.../recording.wav"}
  ... UnifiedPipeline 内部进度（progress / event）
{"audio_file":".../recording.wav","chars":15234,"title":"recording.wav","transcript_txt":".../recording.txt","type":"result"}
{"transcript":".../recording.txt","type":"done"}
```

**JSON Lines 事件流（URL）**：
```
{"name":"start","type":"event","mode":"url","url":"https://www.bilibili.com/video/BV1xxx"}
  ... 下载进度 → 转写进度
{"audio_file":".../Downloads/0701091234.mp3","chars":28456,"title":"视频标题","transcript_txt":".../Downloads/0701091234.txt","type":"result"}
{"transcript":".../Downloads/0701091234.txt","type":"done"}
```

**示例**：
```bash
# 本地文件转写
$ audio-note transcribe ~/Documents/AudioNote/Recordings/0701091234.wav
✓ 转写完成：~/Documents/AudioNote/Recordings/0701091234.txt（15234 字）

# URL 自动下载+转写（B站/YouTube 等）
$ audio-note transcribe "https://www.bilibili.com/video/BV1xxx"

# Agent: JSON 模式 + 指定输出目录
$ audio-note transcribe "https://www.youtube.com/watch?v=xxx" --json --output /tmp/out
```

**错误**：
- 本地文件不存在 → 退出码 66，`code: "NO_INPUT"`
- 转写失败 → 退出码 70，`code: "TRANSCRIBE_FAILED"`
- GUI 占用 → 退出码 75，`code: "BUSY"`

---

### 7.6 download — 下载远程音视频

```
audio-note download <url> [--mode audio|video] [--output <目录>] [--cookie none|chrome|safari|firefox|edge|brave] [--force-takeover] [--json] [-v|-q]
```

下载远程音视频（http/https/B站/YouTube/抖音/小红书等）到本地。基于 yt-dlp。

**选项**：
| Flag | 默认值 | 说明 |
|------|--------|------|
| `--mode audio\|video` | `audio` | audio = 只下音频（mp3），video = 下完整视频 |
| `--output <目录>` | settings 中的 `downloads.dir` | 输出目录 |
| `--cookie <来源>` | `none` | Cookie 来源（部分站点需要登录态） |

**JSON Lines 事件流**：
```
{"name":"start","type":"event","url":"https://www.bilibili.com/video/BV1xxx","mode":"audio"}
  ... 下载进度（progress）
{"file":".../Downloads/0701091234.mp3","size_bytes":15234000,"title":"视频标题","uploader":"UP主名","type":"result"}
{"file":".../Downloads/0701091234.mp3","type":"done"}
```

**示例**：
```bash
# 下载 B 站视频音频
$ audio-note download "https://www.bilibili.com/video/BV1xxx"
✓ 下载完成：~/Documents/AudioNote/Downloads/0701091234.mp3（14876KB）

# 下载 YouTube 视频（需 cookie）
$ audio-note download "https://www.youtube.com/watch?v=xxx" --cookie chrome

# 下载完整视频（非仅音频）
$ audio-note download "https://www.bilibili.com/video/BV1xxx" --mode video

# Agent: JSON 模式
$ audio-note download "https://..." --json
```

**错误**：
- 下载失败 → 退出码 74，`code: "DOWNLOAD_FAILED"`
- GUI 占用 → 退出码 75，`code: "BUSY"`

---

## 8. Agent 集成示例

### 8.1 WorkBuddy 自动化配置

在 WorkBuddy 中创建定时任务（RRULE），周期性扫描录音目录并触发转写：

> *"每 10 分钟扫描一次 `~/Documents/AudioNote/Recordings/`，对今天新增的 `.wav` 文件运行 `audio-note transcribe --json`，转写完成后调用 `recording-digest` skill 生成笔记。处理过的文件标记 `.processed` 后缀。"*

### 8.2 Shell 脚本集成

```bash
#!/bin/bash
# 录音 + 转写 + 总结 一键完成

set -e

MODE="${1:-mix}"
DURATION="${2:-0}"

# 1. 录制
echo "🎙️  开始录制（按 Ctrl+C 停止）..."
OUTPUT=$(audio-note record --json --mode "$MODE" --duration "$DURATION" | tee /tmp/record.log | jq -r 'select(.type=="result") | .file')

if [ -z "$OUTPUT" ]; then
    echo "录制失败，未生成文件"
    exit 1
fi
echo "✓ 录制完成：$OUTPUT"

# 2. 转写
echo "📝 转写中..."
RESULT=$(audio-note transcribe "$OUTPUT" --json | jq -r 'select(.type=="result") | .transcript_txt')
echo "✓ 转写完成：$RESULT"

# 3. 字数统计
CHARS=$(wc -m < "$RESULT")
echo "✓ 共 $CHARS 字"

# 4. 输出摘要行
echo "--- 前 10 行 ---"
head -10 "$RESULT"
```

### 8.3 Python Agent 集成

```python
import subprocess
import json
import sys

def audio_note(*args: str) -> list[dict]:
    """运行 audio-note --json 并返回解析后的事件列表"""
    cmd = ["/usr/local/bin/audio-note", "--json", *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    
    events = []
    for line in proc.stdout.strip().split("\n"):
        if line:
            events.append(json.loads(line))
    
    # 检查错误
    for e in events:
        if e.get("type") == "error":
            raise RuntimeError(f"[{e.get('code')}] {e.get('message')}")
    
    return events

# 列出系统音频设备
events = audio_note("device", "list", "--kind", "system")
for e in events:
    if e.get("type") == "row":
        print(f"  [{e['id']}] {e['name']} {'(默认)' if e.get('selected') else ''}")

# 设置录音目录
audio_note("settings", "set", "recording.dir", "~/Recordings")

# 下载+转写
events = audio_note("transcribe", "https://www.bilibili.com/video/BV1xxx")
for e in events:
    if e.get("type") == "result":
        print(f"转写完成：{e['transcript_txt']}（{e['chars']} 字）")
```

### 8.4 常见 Workflow 速查

| 需求 | 命令 |
|------|------|
| 查看默认录制设备 | `audio-note device default get` |
| 设置麦克风为 AirPods | `audio-note device default set --kind mic --device "AirPods"` |
| 录制系统音频 30 分钟 | `audio-note record --mode system --duration 1800` |
| 混录会议（静音 15 分自动停） | `audio-note record --mode mix --silence-timeout-min 15` |
| 下载 B 站视频转文本 | `audio-note transcribe "https://www.bilibili.com/video/BV1xxx"` |
| 下载 YouTube 音频 | `audio-note download "https://www.youtube.com/watch?v=xxx" --cookie chrome` |
| 查录音库 | `audio-note library list --status completed` |
| 导出转写到桌面 | `audio-note library export <id> --to ~/Desktop/notes.txt` |
| 重置所有配置 | `audio-note settings reset --all` |
| Agent 批量查设备 | `audio-note device list --json \| jq 'select(.type=="row")'` |
| 强制接管 GUI | 任意命令加 `--force-takeover` |
