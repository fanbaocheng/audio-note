---
name: audio-note-cli
description: |
  Integration with the AudioNote CLI (`audio-note` command-line tool) for audio recording, transcription, downloading, device management, and library operations. This skill covers all 14 subcommands (device, settings, library, record, transcribe, download) with JSON Lines protocol parsing, BSD sysexits exit code handling, and single-instance lock management. Trigger when the user needs to: record system/mic/mixed audio, transcribe local files or URLs, download remote media, manage audio devices, view/configure settings, or query the recording library. Always use --json mode for agent consumption; parse stdout line-by-line as JSON Lines events. Handles mutex conflicts (exit 75) with --force-takeover guidance.
description_zh: AudioNote CLI 命令行集成 — 录音 / 转写 / 下载 / 设备管理
description_en: AudioNote CLI — Record / Transcribe / Download / Device management
disable: false
agent_created: true
---

# audio-note-cli

## When to use

Use this skill whenever the user wants to:

- **Record audio**: system audio, microphone, or mixed — from CLI
- **Transcribe audio/video**: local files (wav/mp3/m4a/mp4) or remote URLs (B站/YouTube/etc.)
- **Download media**: download audio/video from URLs via yt-dlp
- **Manage audio devices**: list, refresh, set default system/mic devices
- **View/change settings**: read/write AudioNote config (shared with GUI)
- **Query the library**: list tasks, view details, export transcripts, delete entries

This skill assumes `audio-note` is installed at `/usr/local/bin/audio-note`.

## How it works

The CLI has 6 top-level subcommands (14 total sub-subcommands). All subcommands support `--json` mode, where stdout is 100% JSON Lines (one JSON object per line, `fflush(stdout)` after each line). Non-JSON logs and progress go to stderr only.

### Global flags (available on all subcommands)

| Flag | Effect |
|------|--------|
| `--json` | stdout = JSON Lines; stderr = silent unless `-v` |
| `-v, --verbose` | Detailed logs to stderr |
| `-q, --quiet` | Silent except errors |
| `--force-takeover` | Force-takeover GUI lock (record/transcribe/download only) |

---

## Checklist: before running any command

1. **Verify binary exists**: `ls /usr/local/bin/audio-note` or `which audio-note`
2. **If not installed**: guide the user: `cd AudioNote && swift build -c release && sudo cp .build/arm64-apple-macosx/release/audio-note /usr/local/bin/`
3. **ALWAYS use --json** for agent consumption. Parse stdout line-by-line with a JSON parser.
4. **Check exit code**:
   - `0` → success, check events for `type: "result"` / `type: "done"`
   - `75` → mutex busy, suggest `--force-takeover` or closing GUI
   - `64` → usage error, fix arguments
   - `66` → input not found (file/device doesn't exist)
   - `70` → internal error (bug)
   - `74` → IO error (disk/network/permissions)

### JSON Lines event types

| type | Meaning | Key fields |
|------|---------|------------|
| `info` | Informational message | `message` |
| `row` | Data row (list commands) | varies by command |
| `done` | End of row stream or operation | `count` (for lists) or command-specific fields |
| `result` | Final result payload | varies by command |
| `progress` | Progress update (record/download/transcribe) | `elapsed_sec`, `rms_level`, `silence_seconds` |
| `event` | Lifecycle event | `name` (e.g. "started", "silence_timeout", "cancelled") |
| `error` | Error | `code`, `message`, `details` (optional) |

Normal event sequence: `event` → [`progress` / `row` ...] → `result` → `done`
Error can appear at any point, followed by non-zero exit code.

---

## Subcommand reference

### 1. device — Audio device management

#### device list
```
audio-note device list [--kind system|mic|all] --json
```
Lists audio input devices. `--kind system` = loopback/system devices, `--kind mic` = microphones, `--kind all` (default) = both.

**JSON row fields**: `id` (number), `kind` ("system"/"mic"), `name` (string), `uid` (string), `selected` (bool)

**Use case**: Agent discovers available devices before recording.

#### device refresh
```
audio-note device refresh --json
```
Re-scans available devices. Returns `result` with `device_count`.

#### device default get
```
audio-note device default get --json
```
Shows current default system/mic devices. **JSON result**: `system` and `mic` objects with `id`/`uid`/`name`.

#### device default set
```
audio-note device default set --kind system|mic --device <id|uid|name> --json
```
Persists default device (shared with GUI). Device identifier can be numeric ID, UID string, or device name.

---

### 2. settings — Read/write shared config

#### settings list
```
audio-note settings list --json
```
Lists all 9 config keys with current values.

**JSON row fields**: `key`, `value`, `description`

**Config keys**:
| Key | Description |
|-----|-------------|
| `downloads.cookie_source` | Cookie source: none/chrome/safari/firefox/edge/brave |
| `downloads.dir` | Download output directory |
| `downloads.max_concurrent` | Max concurrent downloads |
| `recording.dir` | Recording output directory |
| `recording.mode` | Recording mode: system/mic/mix |
| `recording.silence_timeout_min` | Silence auto-stop threshold (minutes) |
| `recording.mix.system_gain` | Mix system gain (0..2) |
| `recording.mix.mic_gain` | Mix mic gain (0..2) |
| `recording.mix.keep_originals` | Keep original tracks after mix |

#### settings get
```
audio-note settings get <key> [--raw] --json
```
Read a single config value. Use `--raw` for bare value (no `key = ` prefix) — useful for shell scripts.

**JSON result**: `{"key": "...", "value": "...", "type": "result"}`

#### settings set
```
audio-note settings set <key> <value> --json
```
Write a config value. Persisted to UserDefaults, visible to GUI on next launch.

#### settings reset
```
audio-note settings reset [<key>] [--all] --json
```
Reset one or all config keys to defaults.

---

### 3. library — Recording library & task management

#### library list
```
audio-note library list [--status all|completed|failed|pending|running] --json
```
Lists all tasks + orphan audio files. Tasks with `id: "(file)"` are unprocessed orphan files.

**JSON row fields**: `id`, `title`, `status`, `audio` (path), `transcript` (path), `chars`, `created` (ISO 8601)

#### library show
```
audio-note library show <id> --json
```
Shows full task details. `<id>` = task ID prefix (at least 4 chars).

#### library export
```
audio-note library export <id> [--kind audio|transcript] [--to <path>] --json
```
Copies audio or transcript to specified path. Default `--kind transcript`. If `--to` is a directory, source filename is auto-appended.

#### library delete
```
audio-note library delete <id> [--with-files] --json
```
Deletes task record. `--with-files` also deletes audio and transcript files (**irreversible** — warn the user before using).

---

### 4. record — Audio recording

```
audio-note record --json [--mode system|mic|mix] [--device <id|uid|name>] [--device-mic <id|uid|name>]
                       [--duration <seconds>] [--silence-timeout-min <minutes>]
                       [--auto-enqueue|--no-auto-enqueue] [--force-takeover]
```

**IMPORTANT**: Recording is a long-running command. Parse stdout line-by-line while the process is running (don't wait for exit). Progress events arrive every 0.5s.

**JSON event stream**:
```
{"name":"started","type":"event","mode":"mix","system_device":"BlackHole 2ch","mic_device":"MacBook Pro麦克风","silence_timeout_min":15,"duration_limit_sec":0}
{"elapsed_sec":1,"rms_level":0.023,"silence_seconds":0,"type":"progress"}
{"elapsed_sec":1,"rms_level":0.018,"silence_seconds":0,"type":"progress"}
  ... every 0.5s ...
{"elapsed_sec":45,"rms_level":0.0,"silence_seconds":300,"type":"progress"}
{"name":"silence_timeout","type":"event","seconds":300}
{"file":"/Users/.../0701091234.wav","size_bytes":1204224,"duration_sec":45,"mode":"mix","stop_reason":"silence_timeout","queued_for_transcribe":true,"type":"result"}
{"file":"/Users/.../0701091234.wav","type":"done"}
```

**Stop reasons** (in result `stop_reason`):
- `signal`: Ctrl+C / SIGTERM
- `silence_timeout`: silence exceeded threshold
- `duration_limit`: reached `--duration` limit

**Exit codes for record**:
- `75`: GUI is running (use `--force-takeover`)
- `66`: device not found or not configured
- `70`: recording start failed
- `74`: recording too short, no file generated

**Agent recipe — record and get file path**:
```python
import subprocess, json

proc = subprocess.Popen(
    ["audio-note", "record", "--json", "--mode", "mix", "--duration", "300"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
)
result = None
for line in proc.stdout:
    event = json.loads(line)
    if event.get("type") == "result":
        result = event
    elif event.get("type") == "progress":
        print(f"Recording... {event['elapsed_sec']}s RMS={event['rms_level']:.3f}")
    elif event.get("type") == "error":
        print(f"Error: {event['message']}")
proc.wait()
print(f"Done: {result['file']}" if result else "No file produced")
```

---

### 5. transcribe — Transcribe audio/video

```
audio-note transcribe <input> --json [--output <dir>] [--download-mode audio|video] [--force-takeover]
```

- `<input>` is a local file path → direct transcription
- `<input>` is a URL (http/https) → auto-download audio then transcribe

Uses sherpa-onnx + SenseVoice model (offline, ~85-92% accuracy).

**JSON event stream**:
```
{"name":"start","type":"event","mode":"file","file":"/Users/.../recording.wav"}
  ... (internal progress/events from UnifiedPipeline) ...
{"audio_file":"/Users/.../recording.wav","chars":15234,"title":"recording.wav","transcript_txt":"/Users/.../recording.txt","type":"result"}
{"transcript":"/Users/.../recording.txt","type":"done"}
```

**Key result fields**: `audio_file`, `transcript_txt`, `chars` (character count), `title`

**Exit codes for transcribe**:
- `66`: input file not found
- `70`: transcription failed
- `75`: GUI lock conflict

---

### 6. download — Download remote media

```
audio-note download <url> --json [--mode audio|video] [--output <dir>] [--cookie none|chrome|safari|firefox|edge|brave] [--force-takeover]
```

Downloads remote audio/video via yt-dlp. Supports B站/YouTube/抖音/小红书/etc.

**JSON event stream**:
```
{"name":"start","type":"event","url":"https://...","mode":"audio"}
  ... progress ...
{"file":"/Users/.../0701091234.mp3","size_bytes":15234000,"title":"标题","uploader":"UP主名","type":"result"}
{"file":"/Users/.../0701091234.mp3","type":"done"}
```

**Key result fields**: `file`, `size_bytes`, `title`, `uploader`

**Exit codes for download**:
- `74`: download failed (network/URL error)
- `75`: GUI lock conflict

---

## Lock conflict handling

CLI and GUI share a single-instance lock. When the CLI encounters a conflict:

1. **Detect**: exit code `75`, JSON error `{"code":"BUSY", "details":{"holder":"AudioNoteGui","pid":"...", "mode":"gui"}}`
2. **Response**: If the user is present, ask: "GUI is running. Close it and retry, or use --force-takeover?"
3. **Auto-retry with --force-takeover**: The CLI will SIGTERM the GUI (5s deadline), then acquire the lock
4. **Do NOT force-takeover silently**: Always inform the user before using `--force-takeover`

---

## Common workflow recipes

### Recipe A: Record meeting → transcribe → summarize
```bash
# 1. Ensure mix recording is configured
audio-note device default set --kind system --device "BlackHole 2ch"

# 2. Record (will auto-enqueue for GUI; or transcribe directly after)
audio-note record --json --mode mix --silence-timeout-min 15 > /tmp/record.jsonl

# 3. Extract file path from JSON lines
FILE=$(cat /tmp/record.jsonl | jq -r 'select(.type=="result") | .file')

# 4. Transcribe
audio-note transcribe "$FILE" --json > /tmp/transcribe.jsonl

# 5. Extract transcript path
TXT=$(cat /tmp/transcribe.jsonl | jq -r 'select(.type=="result") | .transcript_txt')

# 6. Agent: read transcript, generate meeting minutes via recording-digest skill
```

### Recipe B: Download B站 video → transcribe → extract key points
```bash
audio-note transcribe "https://www.bilibili.com/video/BV1xxx" --json > /tmp/result.jsonl
TXT=$(cat /tmp/result.jsonl | jq -r 'select(.type=="result") | .transcript_txt')
# Agent: read $TXT, extract key points
```

### Recipe C: Check recording setup
```bash
# Check devices
audio-note device list --json

# Check current defaults
audio-note device default get --json

# Check settings
audio-note settings list --json

# Fix if needed
audio-note settings set recording.dir ~/Recordings --json
```

### Recipe D: Query library and export
```bash
# Find completed tasks
audio-note library list --status completed --json

# Export transcript of a specific task
audio-note library export <id> --kind transcript --to ~/Desktop/notes.txt

# Delete old tasks (with files)
audio-note library delete <id> --with-files
```

---

## Error recovery patterns

| Symptom | Likely cause | Action |
|---------|-------------|--------|
| exit `75`, `"code":"BUSY"` | GUI is running | Ask user to close GUI or retry with `--force-takeover` |
| exit `66`, `"code":"NOT_FOUND"` | Device/file doesn't exist | Run `device list` to verify, check file path |
| exit `66`, `"code":"NO_DEVICE"` | No default device set | Run `device list` → `device default set` |
| exit `74`, `"code":"DOWNLOAD_FAILED"` | Network/URL issue | Check URL, try `--cookie chrome` for logged-in sites |
| exit `74`, `"code":"RECORD_EMPTY"` | Recording too short | Re-record with longer duration |
| exit `70`, `"code":"TRANSCRIBE_FAILED"` | ASR model missing | Run GUI dependency panel or check `~/.cache/sherpa-onnx-models/` |

---

## ASR accuracy note (for agents)

The sherpa-onnx SenseVoice model has ~85-92% accuracy. Proper nouns, English terms, names, and numbers may be misrecognized. When generating summaries from transcripts:
- Cross-reference with domain knowledge (project names, colleague names, technical terms)
- Mark low-confidence segments with `[?]` rather than guessing
- Preserve original timestamps/line numbers for traceability
- For critical content (numbers, dates, URLs), flag as "low confidence, verify manually"

## Dependencies
- `audio-note` binary at `/usr/local/bin/audio-note` (or adjust path)
- Python venv + sherpa-onnx model (handled by AudioNote's dependency panel)
- BlackHole virtual audio device (for system audio recording)
- `jq` recommended for JSON Lines parsing in shell scripts

## Pitfalls

- **Don't wait for record to exit before reading stdout**: Recording is interactive — parse stdout line-by-line while running
- **Don't use `--json` and `--quiet` together without reading stderr**: Errors still appear in stderr or as JSON error events
- **Don't assume device IDs are stable**: Device IDs change across reboots; use UIDs or names for persistence (set via `device default set`)
- **Don't force-takeover without informing user**: `--force-takeover` SIGTERMs the GUI process
- **Don't use `--with-files` on library delete without warning**: This deletes audio and transcript files irreversibly
