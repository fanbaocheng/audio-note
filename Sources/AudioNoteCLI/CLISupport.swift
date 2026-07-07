import Foundation
import ArgumentParser
import AudioNoteCore

// MARK: - 全局 flag 模板

/// 所有子命令都包含的全局 flag 块。每个 subcommand 声明 `@OptionGroup var common: CommonOptions`。
struct CommonOptions: ParsableArguments {
    @Flag(name: .long, help: "stdout 输出 JSON Lines（结构化，便于 agent 解析）")
    var json = false

    @Flag(name: .shortAndLong, help: "详细日志（写 stderr）")
    var verbose = false

    @Flag(name: .shortAndLong, help: "静默模式（除错误外不输出）")
    var quiet = false

    /// 当 stdout 必须 100% JSON 时，所有打印都走 CLIOut；不要直接 print()
    func applyOutputMode() {
        CLIOut.config = OutputConfig(json: json, verbose: verbose, quiet: quiet)
    }
}

/// 是否要求 SingleInstanceLock（不需要锁的命令：device list / settings 等纯查询；需要锁的：record / transcribe / download）
extension CommonOptions {
    func acquireLockOrExit(forceTakeover: Bool, mode: SingleInstanceLock.Mode = .cli) -> SingleInstanceLock {
        switch SingleInstanceLock.acquire(mode: mode, forceTakeover: forceTakeover) {
        case .acquired(let lock):
            return lock
        case .conflict(let holder):
            CLIOut.error("AudioNote 已在运行：\(holder.description)，请先关闭。可加 --force-takeover 强制接管。",
                         code: "BUSY", details: ["holder": holder.description, "pid": holder.pid, "mode": holder.mode.rawValue])
            Exit.busy.terminate()
        case .error(let err):
            CLIOut.error("获取互斥锁失败：\(err)", code: "LOCK_ERROR")
            Exit.osError.terminate()
        }
    }
}

// MARK: - 退出码（BSD sysexits）

enum ExitCode {
    static let success: Int32 = 0
    static let usage: Int32 = 64       // EX_USAGE
    static let dataErr: Int32 = 65     // EX_DATAERR
    static let noInput: Int32 = 66     // EX_NOINPUT
    static let unavailable: Int32 = 69 // EX_UNAVAILABLE
    static let software: Int32 = 70    // EX_SOFTWARE
    static let osError: Int32 = 71     // EX_OSERR
    static let cantCreate: Int32 = 73  // EX_CANTCREAT
    static let ioErr: Int32 = 74       // EX_IOERR
    static let tempFail: Int32 = 75    // EX_TEMPFAIL
    static let busy: Int32 = 75        // 占用：用 EX_TEMPFAIL 表示"暂时不可用"
}

/// 用法：`Exit.busy.terminate()`，封装常用退出场景。
enum Exit {
    case success
    case busy
    case osError
    case noInput
    case software
    case usage
    case ioErr

    func terminate() -> Never {
        switch self {
        case .success:  exit(ExitCode.success)
        case .busy:     exit(ExitCode.busy)
        case .osError:  exit(ExitCode.osError)
        case .noInput:  exit(ExitCode.noInput)
        case .software: exit(ExitCode.software)
        case .usage:    exit(ExitCode.usage)
        case .ioErr:    exit(ExitCode.ioErr)
        }
    }
}

// MARK: - 输出适配

struct OutputConfig {
    var json: Bool = false
    var verbose: Bool = false
    var quiet: Bool = false
}

/// CLI 统一输出层
///
/// 默认模式：human-readable，stdout = 结果，stderr = 日志/进度。
/// `--json`：stdout 100% JSON Lines（每行一个对象 `{type, ...}`），stderr 静默（除非 --verbose）。
enum CLIOut {
    static var config: OutputConfig = .init()
    private static let stderr = FileHandle.standardError

    // MARK: 正常输出

    static func info(_ text: String) {
        guard !config.quiet else { return }
        if config.json {
            emit(["type": "info", "message": text])
        } else {
            print(text)
        }
    }

    /// 结果输出（成功时的主要 payload）
    static func result(_ payload: [String: Any], humanText: String? = nil) {
        if config.json {
            var p = payload
            p["type"] = "result"
            emit(p)
        } else if let h = humanText {
            print(h)
        } else {
            // 没给 human 文案时退化为 JSON
            emit(payload)
        }
    }

    /// 表格输出（device list / library list 等）
    static func table(rows: [[String: Any]], columns: [(key: String, header: String, width: Int?)], emptyText: String = "(empty)") {
        if config.json {
            for r in rows {
                var rr = r; rr["type"] = "row"; emit(rr)
            }
            emit(["type": "done", "count": rows.count])
        } else {
            if rows.isEmpty { print(emptyText); return }
            // 计算列宽
            let widths = columns.map { col -> Int in
                if let w = col.width { return w }
                let valW = rows.map { String(describing: $0[col.key] ?? "") }.map { displayWidth($0) }.max() ?? 0
                return max(displayWidth(col.header), valW)
            }
            // 输出表头
            let header = zip(columns, widths).map { (col, w) in pad(col.header, w) }.joined(separator: "  ")
            print(header)
            print(zip(columns, widths).map { (_, w) in String(repeating: "─", count: w) }.joined(separator: "  "))
            for r in rows {
                let line = zip(columns, widths).map { (col, w) -> String in
                    pad(String(describing: r[col.key] ?? ""), w)
                }.joined(separator: "  ")
                print(line)
            }
            _ = widths
        }
    }

    /// 进度事件（仅 --json 时输出到 stdout；human 模式只在 verbose 时走 stderr）
    static func progress(_ payload: [String: Any]) {
        if config.json {
            var p = payload; p["type"] = "progress"; emit(p)
        } else if config.verbose {
            logErr("[progress] \(payload)")
        }
    }

    /// 通用事件
    static func event(_ name: String, payload: [String: Any] = [:]) {
        if config.json {
            var p = payload; p["type"] = "event"; p["name"] = name; emit(p)
        } else if config.verbose {
            logErr("[event] \(name) \(payload.isEmpty ? "" : "\(payload)")")
        }
    }

    /// 完成事件
    static func done(_ payload: [String: Any] = [:]) {
        if config.json {
            var p = payload; p["type"] = "done"; emit(p)
        }
    }

    // MARK: 错误

    /// 错误：写 stderr（human）或 stdout（json 模式，JSON Lines 仍走 stdout）。
    static func error(_ message: String, code: String = "ERROR", details: [String: Any] = [:]) {
        if config.json {
            var p: [String: Any] = ["type": "error", "code": code, "message": message]
            if !details.isEmpty { p["details"] = details }
            emit(p)
        } else {
            logErr("✗ \(message)")
        }
    }

    /// 写 stderr（不论模式都允许）
    static func logErr(_ s: String) {
        if let data = (s + "\n").data(using: .utf8) {
            stderr.write(data)
        }
    }

    // MARK: 内部

    private static func emit(_ payload: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
            // 立即 flush（让 agent 流式拿到）；标准输出对终端/管道 synchronize 会抛异常，用 fflush(stdout) 即可。
            fflush(stdout)
        }
    }

    private static func displayWidth(_ s: String) -> Int {
        // 中文 1 字符 = 2 列；ASCII = 1 列
        var w = 0
        for u in s.unicodeScalars { w += u.value > 0x7F ? 2 : 1 }
        return w
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        let cur = displayWidth(s)
        if cur >= width { return s }
        return s + String(repeating: " ", count: width - cur)
    }
}

// MARK: - 信号处理（Ctrl+C 优雅停止 / SIGTERM force-takeover 接管）

enum SignalHandler {
    private static var shutdownCallback: (() -> Void)?
    private static var installed = false

    /// 注册"优雅停止"回调。CLI 收到 SIGINT/SIGTERM 时调用，之后 exit(0)。
    static func install(onShutdown: @escaping () -> Void) {
        shutdownCallback = onShutdown
        guard !installed else { return }
        installed = true
        signal(SIGINT) { _ in SignalHandler.handle() }
        signal(SIGTERM) { _ in SignalHandler.handle() }
        // 忽略 SIGPIPE（agent 关闭 stdout 时不要崩）
        signal(SIGPIPE, SIG_IGN)
    }

    private static func handle() {
        // 仅触发业务回调（停止录音 / 释放锁）。真正的退出由主循环检测到停止标志后
        // 走正常的 teardown（enqueue + await 转写 + exit）完成，避免在信号上下文里直接 exit(0)
        // 导致录制/转写结果在写入磁盘前被进程终止而丢失。
        shutdownCallback?()
    }
}
