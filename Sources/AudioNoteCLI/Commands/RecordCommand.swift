import Foundation
import ArgumentParser
import AudioNoteCore

/// record 子命令：复用 AudioCaptureEngine 进行录音。
///
/// 设计：
/// - 默认无时长上限；通过 Ctrl+C(SIGINT) / SIGTERM 优雅停止
/// - 静音自动停止逻辑完全沿用 GUI（onSilenceTimeout）
/// - 录制完毕落地到 GUI 同目录，并将文件 enqueue 到 TaskScheduler 让 GUI 下次启动看到（用户可选 --no-auto-transcribe 关闭）
struct RecordCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "record",
        abstract: "录制系统音频 / 麦克风 / 混合 → wav；按 Ctrl+C 停止",
        discussion: """
        输出目录由 settings 中的 recording.dir 决定（与 GUI 共享）：
          audio-note settings set recording.dir ~/Recordings
        如需自定义目录，请先设置 recording.dir；文件名按时间戳自动生成。
        """
    )

    @OptionGroup var common: CommonOptions

    @Option(name: .long, help: "录制模式：system / mic / mix（默认按 settings 中的 recording.mode）")
    var mode: String?

    @Option(name: .long, help: "系统音频设备（id 或 uid 或 name）")
    var device: String?

    @Option(name: .long, help: "麦克风设备（id 或 uid 或 name）")
    var deviceMic: String?

    @Option(name: .long, help: "录制最大时长（秒；0 表示无上限，默认 0）")
    var duration: Double = 0

    @Option(name: .long, help: "静音自动停止阈值（分钟；默认沿用 settings，未配置则 5 分钟）")
    var silenceTimeoutMin: Double?

    @Flag(name: .long, inversion: .prefixedNo, exclusivity: .exclusive, help: "录完是否自动加入 GUI 任务队列等待下次启动转写")
    var autoEnqueue: Bool = true

    @Flag(name: .long, help: "占用 GUI 时强制接管（SIGTERM 通知 GUI 退出）")
    var forceTakeover: Bool = false

    @MainActor
    mutating func run() async throws {
        common.applyOutputMode()
        let lock = common.acquireLockOrExit(forceTakeover: forceTakeover)

        let engine = AudioCaptureEngine.shared
        engine.refreshDevices()

        // 解析录制模式
        if let mode {
            guard let m = RecordingMode(rawValue: aliasToMode(mode)) else {
                CLIOut.error("无效 --mode：\(mode)，必须是 system / mic / mix", code: "USAGE")
                throw ExitCodeWrapper(64)
            }
            engine.recordingMode = m
        }

        // 解析设备
        if let device = device {
            if let d = resolveDevice(device, in: engine.availableSystemDevices) {
                engine.selectedSystemDevice = d
            } else {
                CLIOut.error("找不到系统音频设备：\(device)", code: "NOT_FOUND")
                throw ExitCodeWrapper(66)
            }
        }
        if let mic = deviceMic {
            if let d = resolveDevice(mic, in: engine.availableMicDevices) {
                engine.selectedMicDevice = d
            } else {
                CLIOut.error("找不到麦克风设备：\(mic)", code: "NOT_FOUND")
                throw ExitCodeWrapper(66)
            }
        }

        // 静音超时
        if let m = silenceTimeoutMin {
            engine.silenceTimeoutSec = max(60, m * 60)
        }

        // 起录前校验
        switch engine.recordingMode {
        case .systemAudio:
            guard engine.selectedSystemDevice != nil else {
                CLIOut.error("未选择系统音频设备。先运行 `audio-note device list` 查看可用设备，再 --device 指定。", code: "NO_DEVICE")
                throw ExitCodeWrapper(66)
            }
        case .microphone:
            guard engine.selectedMicDevice != nil else {
                CLIOut.error("未选择麦克风设备。先运行 `audio-note device list` 查看，再 --device-mic 指定。", code: "NO_DEVICE")
                throw ExitCodeWrapper(66)
            }
        case .mix:
            guard engine.selectedSystemDevice != nil, engine.selectedMicDevice != nil else {
                CLIOut.error("mix 模式需要同时指定系统音频和麦克风设备", code: "NO_DEVICE")
                throw ExitCodeWrapper(66)
            }
        }

        // 静音停止回调
        let stopReason = StopReason()
        engine.onSilenceTimeout = {
            stopReason.value = "silence_timeout"
            CLIOut.event("silence_timeout", payload: ["seconds": engine.silenceSeconds])
            engine.stopRecording().map { _ in }
            stopReason.shouldExit = true
        }

        // SIGINT/SIGTERM：把锁/录音保存
        SignalHandler.install {
            stopReason.value = "signal"
            _ = engine.stopRecording()
            lock.release()
        }

        // 启动
        engine.startRecording()
        guard engine.isRecording else {
            CLIOut.error("启动录制失败（请查看 stderr 日志）", code: "RECORD_FAILED")
            throw ExitCodeWrapper(70)
        }
        CLIOut.event("started", payload: [
            "mode": engine.recordingMode.rawValue,
            "system_device": engine.selectedSystemDevice?.name ?? "",
            "mic_device": engine.selectedMicDevice?.name ?? "",
            "silence_timeout_min": engine.silenceTimeoutSec / 60,
            "duration_limit_sec": duration
        ])
        if !common.json {
            CLIOut.logErr("● 录制中 [\(engine.recordingMode.displayName)] — 按 Ctrl+C 停止")
        }

        // 主循环：每 0.5s tick 一次，更新进度 / 检查时长上限 / 检查静音停止
        let startedAt = Date()
        let useDurationLimit = duration > 0

        while engine.isRecording && !stopReason.shouldExit {
            try await Task.sleep(nanoseconds: 500_000_000)
            let elapsed = Date().timeIntervalSince(startedAt)
            CLIOut.progress([
                "elapsed_sec": Int(elapsed),
                "rms_level": engine.rmsLevel,
                "silence_seconds": engine.silenceSeconds
            ])
            if !common.json {
                let bar = makeBar(level: engine.rmsLevel, width: 20)
                let timeStr = formatHMS(elapsed)
                CLIOut.logErr("\u{001B}[2K\r⏺  \(timeStr)  [\(bar)] RMS \(String(format: "%.2f", engine.rmsLevel))")
            }
            if useDurationLimit, elapsed >= duration {
                stopReason.value = "duration_limit"
                break
            }
        }

        // 停止
        let finalURL = engine.stopRecording()
        if !common.json { CLIOut.logErr("") } // 换行

        // 录音设备已释放，提前释放互斥锁，避免转写阶段长时间占用 GUI 启动名额
        lock.release()

        guard let outURL = finalURL else {
            CLIOut.error("录音过短或失败，未生成文件", code: "RECORD_EMPTY")
            throw ExitCodeWrapper(74)
        }

        // 可选入队并等待转写完成：CLI 进程必须在 exit 前确保转写已落盘，
        // 否则 exit(0) 会把后台转写子进程一并杀掉（之前的 bug）。
        if autoEnqueue {
            let task = TaskScheduler.shared.enqueueRecording(fileURL: outURL, startImmediately: false)
            await UnifiedPipeline.shared.processRecording(task: task, fileURL: outURL)
            TaskScheduler.shared.persist()
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs?[.size] as? Int) ?? 0

        CLIOut.result([
            "file": outURL.path,
            "size_bytes": size,
            "duration_sec": Int(engine.elapsedTime),
            "mode": engine.recordingMode.rawValue,
            "stop_reason": stopReason.value,
            "queued_for_transcribe": autoEnqueue
        ], humanText: "✓ 录制完成：\(outURL.path)（\(formatHMS(engine.elapsedTime))，\(size / 1024)KB）")
        CLIOut.done(["file": outURL.path])
    }

    // MARK: - helpers

    private func aliasToMode(_ s: String) -> String {
        switch s.lowercased() {
        case "system", "system_audio", "systemaudio", "sys": return "systemAudio"
        case "mic", "microphone": return "microphone"
        case "mix", "both": return "mix"
        default: return s
        }
    }

    private func resolveDevice(_ key: String, in pool: [AudioCaptureEngine.AudioInputDevice]) -> AudioCaptureEngine.AudioInputDevice? {
        if let did = UInt32(key) { return pool.first(where: { $0.id == did }) }
        return pool.first(where: { $0.uid == key || $0.name == key })
    }

    private func formatHMS(_ t: TimeInterval) -> String {
        let tt = Int(t.rounded())
        let h = tt / 3600, m = (tt % 3600) / 60, s = tt % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    private func makeBar(level: Float, width: Int) -> String {
        let cap = max(0, min(1, Double(level)))
        let filled = Int((cap * Double(width)).rounded())
        return String(repeating: "█", count: filled) + String(repeating: "·", count: max(0, width - filled))
    }
}

/// 闭包逃逸捕获用的可变状态包
final class StopReason {
    var value: String = "unknown"
    var shouldExit: Bool = false
}
