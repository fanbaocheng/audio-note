import Foundation

/// 定位运行时依赖: yt-dlp / ffmpeg / python3 / transcribe.py
public enum BinaryResolver {
    public static func ytdlpURL() -> URL? {
        if let bundled = bundledBinary(name: "yt-dlp") { return bundled }
        return findOnPath("yt-dlp")
    }

    public static func ffmpegURL() -> URL? {
        if let bundled = bundledBinary(name: "ffmpeg") { return bundled }
        return findOnPath("ffmpeg")
    }

    public static func python3URL() -> URL? {
        // 优先 /usr/local/bin/python3（AudioTranscriber 装 sherpa-onnx 的环境）
        let preferred = "/usr/local/bin/python3"
        if FileManager.default.isExecutableFile(atPath: preferred) {
            return URL(fileURLWithPath: preferred)
        }
        return findOnPath("python3")
    }

    public static func transcribePyURL() -> URL? {
        // 1. bundle Resources/scripts
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("scripts/transcribe.py"),
           FileManager.default.fileExists(atPath: resURL.path) { return resURL }
        // 2. SwiftPM 开发期
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let dev = exe.deletingLastPathComponent().appendingPathComponent("Resources/scripts/transcribe.py")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        // 3. 工程根 scripts/
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let local = cwd.appendingPathComponent("scripts/transcribe.py")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        // 4. PKM 兜底
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pkm = home.appendingPathComponent("个人资料/PKM/tool/AudioTranscriber/scripts/transcribe.py")
        if FileManager.default.fileExists(atPath: pkm.path) { return pkm }
        return nil
    }

    public static func diagnostic() -> String {
        let yt = ytdlpURL()?.path ?? "NOT FOUND"
        let ff = ffmpegURL()?.path ?? "NOT FOUND"
        let py = python3URL()?.path ?? "NOT FOUND"
        let tr = transcribePyURL()?.path ?? "NOT FOUND"
        return "yt-dlp: \(yt)\nffmpeg: \(ff)\npython3: \(py)\ntranscribe.py: \(tr)"
    }

    private static func bundledBinary(name: String) -> URL? {
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("vendor/\(name)"),
           FileManager.default.isExecutableFile(atPath: resURL.path) { return resURL }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let dev = exe.deletingLastPathComponent().appendingPathComponent("Resources/vendor/\(name)")
        if FileManager.default.isExecutableFile(atPath: dev.path) { return dev }
        return nil
    }

    private static func findOnPath(_ name: String) -> URL? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = ["which", name]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        if task.terminationStatus == 0,
           let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
            let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
