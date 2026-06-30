import Foundation

/// 音频混音工具：用 ffmpeg amix 把两路 wav 合并为一路
///
/// 用于 mix 模式录制结束后的后处理：
///   ffmpeg -y -i sys.wav -i mic.wav \
///          -filter_complex "[0:a]volume=W1[a];[1:a]volume=W2[b];[a][b]amix=inputs=2:duration=longest:dropout_transition=0[out]" \
///          -map "[out]" -ac 1 -ar <sr> output.wav
///
/// 设计要点：
/// - 同步阻塞调用（一般录音 30 分钟以内合并耗时 <2s）
/// - 失败时返回 false，调用方负责回退
/// - 不抛异常，所有错误走 Logger
enum AudioMixer {

    /// 合并两路 wav
    /// - Parameters:
    ///   - systemURL: 系统音频路 wav
    ///   - systemGain: 系统音频增益（0.0 ~ 2.0+）
    ///   - micURL: 麦克风路 wav
    ///   - micGain: 麦克风增益
    ///   - outputURL: 输出 wav（pcm_s16le mono）
    /// - Returns: 成功返回 true
    @discardableResult
    static func merge(systemURL: URL,
                      systemGain: Float,
                      micURL: URL,
                      micGain: Float,
                      outputURL: URL) -> Bool {
        guard let ffmpeg = BinaryResolver.ffmpegURL() else {
            Logger.recording.error("AudioMixer: ffmpeg 未找到")
            return false
        }
        guard FileManager.default.fileExists(atPath: systemURL.path) else {
            Logger.recording.error("AudioMixer: 系统音频文件不存在 \(systemURL.path)")
            return false
        }
        guard FileManager.default.fileExists(atPath: micURL.path) else {
            Logger.recording.error("AudioMixer: 麦克风文件不存在 \(micURL.path)")
            return false
        }

        // 限幅，避免极端值
        let w1 = max(0.0, min(4.0, Double(systemGain)))
        let w2 = max(0.0, min(4.0, Double(micGain)))

        // amix 默认会按输入数除以 2 来防爆音，这里我们想让 weights 直接生效
        // 所以单路先用 volume 滤镜上增益，再 amix（normalize=0 关掉除数）
        let filter = "[0:a]volume=\(format(w1))[a];" +
                     "[1:a]volume=\(format(w2))[b];" +
                     "[a][b]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0[out]"

        let args: [String] = [
            "-y",
            "-hide_banner",
            "-loglevel", "warning",
            "-i", systemURL.path,
            "-i", micURL.path,
            "-filter_complex", filter,
            "-map", "[out]",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            outputURL.path
        ]

        Logger.recording.info("AudioMixer: ffmpeg amix 启动 w1=\(format(w1)) w2=\(format(w2))")
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()  // 丢弃 stdout

        do {
            try proc.run()
        } catch {
            Logger.recording.error("AudioMixer: ffmpeg 启动失败 \(error.localizedDescription)")
            return false
        }
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "<unreadable>"
            Logger.recording.error("AudioMixer: ffmpeg 退出码=\(proc.terminationStatus) stderr=\(errStr.prefix(500))")
            return false
        }

        // 校验输出文件
        guard FileManager.default.fileExists(atPath: outputURL.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int),
              size > 44 else {
            Logger.recording.error("AudioMixer: 输出文件无效 \(outputURL.path)")
            return false
        }
        Logger.recording.info("AudioMixer: 合并完成 size=\(size/1024)KB -> \(outputURL.lastPathComponent)")
        return true
    }

    private static func format(_ v: Double) -> String {
        // ffmpeg volume 滤镜接受小数字符串
        return String(format: "%.3f", v)
    }
}
