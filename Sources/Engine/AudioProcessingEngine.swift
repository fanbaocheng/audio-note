import Foundation

/// 统一音频处理引擎 — 所有 ffmpeg 调用收敛为此模块
/// 提供：格式转换、音频抽取、重采样、VAD、降噪
@MainActor
final class AudioProcessingEngine {
    static let shared = AudioProcessingEngine()
    private init() {}

    // MARK: - 从视频抽音轨

    /// 从视频文件抽取音轨并标准化为 16kHz mono PCM wav
    func extractAudio(from videoURL: URL, outputDir: URL? = nil) async throws -> URL {
        let outDir = outputDir ?? FileManager.default.temporaryDirectory
        let outName = videoURL.deletingPathExtension().lastPathComponent + "_audio.wav"
        let outURL = outDir.appendingPathComponent(outName)

        guard BinaryResolver.ffmpegURL() != nil else {
            Logger.asr.error("ffmpeg 未找到", metadata: ["video": videoURL.path])
            throw EngineError.binaryMissing("ffmpeg")
        }

        Logger.asr.info("抽取音轨", metadata: ["input": videoURL.lastPathComponent, "output": outURL.lastPathComponent])

        try await runFFmpeg(args: [
            "-i", videoURL.path,
            "-vn", "-acodec", "pcm_s16le",
            "-ar", "16000", "-ac", "1",
            "-y", outURL.path
        ], description: "extractAudio")

        guard FileManager.default.fileExists(atPath: outURL.path) else {
            Logger.asr.error("抽音轨后文件不存在", metadata: ["path": outURL.path])
            throw EngineError.processingFailed("抽音轨失败: 输出文件不存在")
        }

        Logger.asr.info("音轨抽取完成", metadata: ["output": outURL.path])
        return outURL
    }

    /// 重采样音频文件
    func resample(input: URL, sampleRate: Int = 16000, channels: Int = 1, outputDir: URL? = nil) async throws -> URL {
        let outDir = outputDir ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let outURL = outDir.appendingPathComponent("\(stem)_resampled.wav")

        guard BinaryResolver.ffmpegURL() != nil else {
            throw EngineError.binaryMissing("ffmpeg")
        }

        Logger.asr.info("重采样", metadata: ["input": input.lastPathComponent, "rate": sampleRate, "ch": channels])

        try await runFFmpeg(args: [
            "-i", input.path,
            "-acodec", "pcm_s16le",
            "-ar", "\(sampleRate)",
            "-ac", "\(channels)",
            "-y", outURL.path
        ], description: "resample")

        return outURL
    }

    /// 获取音频时长（秒）
    func getDuration(_ audioURL: URL) async -> TimeInterval? {
        guard BinaryResolver.ffmpegURL() != nil else { return nil }
        do {
            let output = try await runFFmpegCapture(args: [
                "-i", audioURL.path,
                "-f", "null", "-"
            ])
            // 从 stderr 解析 Duration
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                if line.contains("Duration:") {
                    let parts = line.components(separatedBy: "Duration: ")
                    if parts.count > 1 {
                        let timePart = parts[1].components(separatedBy: ",").first ?? ""
                        let comps = timePart.components(separatedBy: ":")
                        if comps.count == 3,
                           let h = Double(comps[0]), let m = Double(comps[1]), let s = Double(comps[2]) {
                            return h * 3600 + m * 60 + s
                        }
                    }
                }
            }
        } catch {
            Logger.asr.warn("获取时长失败", metadata: ["error": error.localizedDescription])
        }
        return nil
    }

    // MARK: - Private

    private func runFFmpeg(args: [String], description: String) async throws {
        let process = Process()
        process.executableURL = BinaryResolver.ffmpegURL()!
        process.arguments = args
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
            let errMsg = errData.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
            Logger.asr.error("ffmpeg \(description) 失败", metadata: ["exit": process.terminationStatus, "stderr": errMsg])
            throw EngineError.processingFailed("ffmpeg \(description) failed: \(errMsg.prefix(200))")
        }
    }

    private func runFFmpegCapture(args: [String]) async throws -> String {
        let process = Process()
        process.executableURL = BinaryResolver.ffmpegURL()!
        process.arguments = args
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - Errors

enum EngineError: LocalizedError {
    case binaryMissing(String)
    case processingFailed(String)
    case downloadFailed(String)
    case transcribeFailed(String)
    case parseFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let name):  return "缺少依赖: \(name)"
        case .processingFailed(let m):  return "处理失败: \(m)"
        case .downloadFailed(let m):    return "下载失败: \(m)"
        case .transcribeFailed(let m):  return "转写失败: \(m)"
        case .parseFailed:              return "解析视频信息失败"
        case .cancelled:                return "已取消"
        }
    }
}
