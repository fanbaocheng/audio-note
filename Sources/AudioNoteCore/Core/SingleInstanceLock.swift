import Foundation
import Darwin

/// 单实例互斥锁：保证同一时刻只有一个 AudioNote 进程（GUI 或 CLI）在运行。
///
/// 实现：
/// - 锁文件：`~/Library/Application Support/AudioNote/.lock`
/// - `flock(LOCK_EX | LOCK_NB)`：非阻塞独占锁，被占时立刻返回失败
/// - 文件内容：JSON `{ pid, mode, startedAt, version }`
/// - 释放：`atexit` 注册的 `release()` 会在进程正常退出时清空内容并释放 flock
/// - 脏锁回收：拿不到锁时读取 pid，`kill(pid, 0)` 探活，若进程已死则强制接管
///
/// 用法（GUI / CLI 都走同一路径）：
/// ```
/// switch SingleInstanceLock.acquire(mode: .gui) {
/// case .acquired(let lock): /* 继续启动，保留 lock 引用 */
/// case .conflict(let holder): /* 报错退出，告诉用户 holder.mode (gui/cli) PID 是谁 */
/// case .error(let err): /* fallback：日志后继续 */
/// }
/// ```
public final class SingleInstanceLock {

    // MARK: - 类型

    public enum Mode: String, Codable {
        case gui
        case cli
    }

    public struct Holder: Codable {
        public let pid: Int32
        public let mode: Mode
        public let startedAt: Date
        public let version: String

        public var description: String {
            let modeName = mode == .gui ? "GUI" : "CLI"
            // 用 DateFormatter 显式带本地时区偏移（ISO8601DateFormatter 默认 UTC，不友好）
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
            fmt.locale = Locale(identifier: "en_US_POSIX")
            return "\(modeName) (PID \(pid), since \(fmt.string(from: startedAt)))"
        }
    }

    public enum AcquireResult {
        case acquired(SingleInstanceLock)
        case conflict(Holder)
        case error(String)
    }

    // MARK: - 路径

    public static var lockFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("AudioNote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".lock")
    }

    // MARK: - 实例字段

    private let fd: Int32
    private let url: URL
    public let mode: Mode

    private init(fd: Int32, url: URL, mode: Mode) {
        self.fd = fd
        self.url = url
        self.mode = mode
    }

    // MARK: - 获取/释放

    /// 尝试获取锁。
    /// - Parameter mode: 当前进程身份（gui / cli）
    /// - Parameter forceTakeover: true 时若锁被占用，向持有者发 SIGTERM 等待退出后接管（仅 CLI 用）
    public static func acquire(mode: Mode, forceTakeover: Bool = false) -> AcquireResult {
        let url = lockFileURL

        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            return .error("open(\(url.path)) failed: \(String(cString: strerror(errno)))")
        }

        // 第一次尝试
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return finalizeAcquire(fd: fd, url: url, mode: mode)
        }

        // 拿不到 → 读取持有者信息
        if let holder = readHolder(from: url) {
            // 脏锁检测：kill(pid, 0) 失败说明进程已死
            if kill(holder.pid, 0) != 0 && errno == ESRCH {
                // 进程已死，强制重试
                close(fd)
                _ = try? FileManager.default.removeItem(at: url)
                return retryAcquire(url: url, mode: mode)
            }

            // 进程还活着，看是否 takeover
            if forceTakeover {
                close(fd)
                let outcome = sendTakeoverSignal(to: holder.pid)
                if outcome {
                    return retryAcquire(url: url, mode: mode)
                }
                return .conflict(holder)
            }

            close(fd)
            return .conflict(holder)
        }

        // 锁被占但读不到 holder（极少见，可能是被占用瞬间还没写入）
        close(fd)
        return .error("lock file exists but holder is unreadable")
    }

    private static func retryAcquire(url: URL, mode: Mode) -> AcquireResult {
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            return .error("retry open failed: \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            return finalizeAcquire(fd: fd, url: url, mode: mode)
        }
        let holder = readHolder(from: url)
        close(fd)
        if let h = holder { return .conflict(h) }
        return .error("lock acquired by unknown holder after retry")
    }

    private static func finalizeAcquire(fd: Int32, url: URL, mode: Mode) -> AcquireResult {
        // 写入 holder 信息
        let holder = Holder(pid: getpid(), mode: mode, startedAt: Date(), version: "0.3.0")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(holder) {
            ftruncate(fd, 0)
            lseek(fd, 0, SEEK_SET)
            _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
            fsync(fd)
        }

        let lock = SingleInstanceLock(fd: fd, url: url, mode: mode)
        installAtExitHook(lock: lock)
        return .acquired(lock)
    }

    /// 主动释放（在正常退出时被 atexit hook 调用）
    public func release() {
        if fd >= 0 {
            ftruncate(fd, 0)
            flock(fd, LOCK_UN)
            close(fd)
        }
        // 删除锁文件本身，避免下次启动看到陈旧的 holder 信息（虽然 acquire 会重写但更干净）
        try? FileManager.default.removeItem(at: url)
    }

    deinit { release() }

    // MARK: - 读 holder（无锁也能读，仅文本）

    public static func readHolder(from url: URL? = nil) -> Holder? {
        let u = url ?? lockFileURL
        guard let data = try? Data(contentsOf: u), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Holder.self, from: data)
    }

    // MARK: - --force-takeover SIGTERM 优雅接管

    /// 向持有者发 SIGTERM，等待最多 5 秒。
    /// - Returns: 持有者按时退出返回 true；超时仍存活返回 false（不再 SIGKILL，让用户自己决定）
    private static func sendTakeoverSignal(to pid: Int32) -> Bool {
        // 不杀自己
        if pid == getpid() { return false }
        guard kill(pid, SIGTERM) == 0 else { return false }

        // 等待最多 5 秒
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            // kill 0 探活：返回非 0 且 errno=ESRCH 说明进程已死
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            usleep(100_000) // 100ms
        }
        return false
    }

    // MARK: - atexit hook

    private static var registeredLock: SingleInstanceLock?

    private static func installAtExitHook(lock: SingleInstanceLock) {
        // 只能注册一次 c 函数，且 c 函数不能闭包捕获 → 用 static 引用
        if registeredLock == nil {
            atexit {
                SingleInstanceLock.registeredLock?.release()
            }
        }
        registeredLock = lock
    }
}
