import Foundation
import os

/// 磁盘持久化日志系统 — 所有关键链路强制日志输出
///
/// 日志格式: [HH:mm:ss.SSS] [模块] [方法] 消息
/// 落盘路径: ~/Library/Logs/AudioNote/AudioNote-YYYY-MM-DD.log
/// 同时输出到 stderr（Console.app 可抓）
///
/// 使用方式:
///   Logger.download.info("开始解析", metadata: ["url": url])
///   Logger.asr.error("转写失败", error: err)
///   Logger.recording.warn("静音超时", context: ["silenceSec": 120])
enum Logger {
    // MARK: - 日志级别
    enum Level: String {
        case debug = "DEBUG"
        case info  = "INFO"
        case warn  = "WARN"
        case error = "ERROR"
    }

    // MARK: - 模块定义
    struct ModuleLog {
        let name: String
    }

    static let app       = ModuleLog(name: "APP")
    static let download  = ModuleLog(name: "DOWNLOAD")
    static let recording = ModuleLog(name: "RECORDING")
    static let asr       = ModuleLog(name: "ASR")
    static let pipeline  = ModuleLog(name: "PIPELINE")
    static let scheduler = ModuleLog(name: "SCHEDULER")
    static let storage   = ModuleLog(name: "STORAGE")
    static let cache     = ModuleLog(name: "CACHE")

    // MARK: - 日志文件
    static let logDir: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Logs/AudioNote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logFile: URL = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let name = "AudioNote-\(f.string(from: Date())).log"
        return logDir.appendingPathComponent(name)
    }()

    private static let queue = DispatchQueue(label: "com.ryanfan.audionote.log", qos: .utility)
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: - 写入核心
    static func write(
        _ level: Level,
        module: ModuleLog,
        method: String,
        message: String,
        metadata: [String: Any]? = nil,
        error: Error? = nil,
        file: String = #file,
        line: Int = #line
    ) {
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        var parts: [String] = []
        parts.append("[\(dateFmt.string(from: Date()))]")
        parts.append("[\(level.rawValue)]")
        parts.append("[\(module.name):\(method)]")

        var msg = message
        if let meta = metadata, !meta.isEmpty {
            let metaStr = meta.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            msg += " | \(metaStr)"
        }
        if let err = error {
            msg += " | error=\(err.localizedDescription)"
        }
        msg += " | (\(fileName):\(line))"
        parts.append(msg)

        let fullLine = parts.joined(separator: " ") + "\n"

        queue.async {
            if let data = fullLine.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFile.path) {
                    if let h = try? FileHandle(forWritingTo: logFile) {
                        defer { try? h.close() }
                        _ = try? h.seekToEnd()
                        try? h.write(contentsOf: data)
                    }
                } else {
                    try? data.write(to: logFile)
                }
            }
            FileHandle.standardError.write(fullLine.data(using: .utf8) ?? Data())
        }
    }
}

// MARK: - 便捷方法
extension Logger.ModuleLog {
    func debug(_ message: String, method: String = #function, metadata: [String: Any]? = nil, file: String = #file, line: Int = #line) {
        Logger.write(.debug, module: self, method: method, message: message, metadata: metadata, file: file, line: line)
    }
    func info(_ message: String, method: String = #function, metadata: [String: Any]? = nil, file: String = #file, line: Int = #line) {
        Logger.write(.info, module: self, method: method, message: message, metadata: metadata, file: file, line: line)
    }
    func warn(_ message: String, method: String = #function, metadata: [String: Any]? = nil, file: String = #file, line: Int = #line) {
        Logger.write(.warn, module: self, method: method, message: message, metadata: metadata, file: file, line: line)
    }
    func error(_ message: String, method: String = #function, metadata: [String: Any]? = nil, error: Error? = nil, file: String = #file, line: Int = #line) {
        Logger.write(.error, module: self, method: method, message: message, metadata: metadata, error: error, file: file, line: line)
    }
}
