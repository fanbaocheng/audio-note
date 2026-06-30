import Foundation

/// yt-dlp 下载引擎
///
/// 完整迁移自 MediaDownloader.DownloadEngine（已在 MD 上长期跑稳定）。
/// 关键能力（相对旧版重写）：
/// - `--print after_move:FILEPATH=%(filepath)s` 精确拿最终路径
/// - 退出 0 但无 FILEPATH → `parseAlreadyDownloaded` 兜底（处理"已下载过"场景）
/// - 站点 headers：B 站/抖音/微博/小红书 UA + Referer 注入
/// - 网络稳健性：retry 10 / fragment-retries 10 / linear retry-sleep / socket timeout / 10MB chunk / force-ipv4 / legacy-server-connect
/// - 错误归纳：`summarizeError` 把 yt-dlp 的乱序 stderr 提炼成一句给用户看的提示
/// - 元信息：`--print` 模板 + `⟦|⟧` 罕见分隔符（避免 title/uploader 含 `|` 导致解析炸）
///
/// 适配 AudioNote：
/// - 类签名沿用 `DownloadEngine`，提供 `static let shared` 单例
/// - 入参从 `DownloadTask` 改为 `UniTask`（沿用现有 AudioNote 模型）
/// - 路径设置改走 `Config` 包结构，UnifiedPipeline 直接传 `config`
/// - 日志改走 Logger.download（替代 MD 的 `AppLog`）
/// - 错误类型对齐 `EngineError`（已在 AudioProcessingEngine.swift 扩展 cancelled / parseFailed）
@MainActor
public final class DownloadEngine {
    public static let shared = DownloadEngine()
    private init() {}

    public struct Config {
        public var outputDir: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudioNote/Downloads")
        public var cookieSource: CookieSource = .none
        public var ffmpegLocation: URL? = nil
    }

    public var config = Config()

    // MARK: - 公共 API

    /// 执行下载任务
    public func execute(task: UniTask) async throws -> URL {
        guard let url = task.sourceURL, !url.isEmpty else {
            throw EngineError.downloadFailed("sourceURL 为空")
        }
        guard let ytdlp = BinaryResolver.ytdlpURL() else {
            Logger.download.error("yt-dlp 二进制未找到")
            throw EngineError.binaryMissing("yt-dlp")
        }

        Logger.download.info("===== 开始下载 =====", metadata: [
            "url": url,
            "mode": task.downloadMode.rawValue,
            "ytdlp": ytdlp.path,
            "cookie": config.cookieSource.rawValue,
            "outDir": config.outputDir.path
        ])

        // Stage 1: 解析元信息
        task.status = .resolving
        do {
            let meta = try await resolveMetadata(url: url, ytdlp: ytdlp, cookie: config.cookieSource)
            if let t = meta.title, !t.isEmpty { task.title = t }
            task.uploader = meta.uploader
            task.duration = meta.duration
            if let thumb = meta.thumbnail { task.thumbnailURL = URL(string: thumb) }
            Logger.download.info("元信息解析完成", metadata: [
                "title": meta.title ?? "?",
                "uploader": meta.uploader ?? "?",
                "duration": meta.duration ?? 0
            ])
        } catch {
            Logger.download.warn("元信息解析失败，继续尝试直接下载", metadata: ["error": error.localizedDescription])
        }

        task.status = .downloading
        let now = Date()
        task.startedAt = task.startedAt ?? now
        task.downloadStartedAt = now

        // Stage 2: 构造下载参数
        try FileManager.default.createDirectory(at: config.outputDir, withIntermediateDirectories: true)

        let stamp = Self.makeTimestamp()
        // 统一命名规则：MMDDHHMMSS.xxx（不带标题/ID）
        let outputTemplate = config.outputDir.appendingPathComponent("\(stamp).%(ext)s").path
        var args: [String] = [
            "--newline",
            "--progress",
            "--no-mtime",
            "--no-playlist",
            "--restrict-filenames",
            "-o", outputTemplate,
            "--print", "after_move:FILEPATH=%(filepath)s",
            "--retries", "10",
            "--fragment-retries", "10",
            "--retry-sleep", "linear=1:5:1",
            "--socket-timeout", "30",
            "--http-chunk-size", "10485760",
            "--force-ipv4",
            "--legacy-server-connect"
        ]
        args.append(contentsOf: Self.siteHeaders(for: url))

        // 格式选择
        switch task.downloadMode {
        case .video:
            args.append(contentsOf: ["-f", "bestvideo*+bestaudio/best", "--merge-output-format", "mp4"])
        case .audio:
            // 与 MediaDownloader 对齐：落盘存 mp3（压缩、文件小），转写时由 ASRService 临时 ffmpeg 转 wav
            // 之前用 wav 持久化是错误的：PCM WAV 1536kbps，2.5h ≈ 1.85GB；改 mp3 后 2.5h ≈ 200MB
            args.append(contentsOf: ["-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "0"])
        }

        // Cookie
        if let c = config.cookieSource.ytdlpValue {
            args.append(contentsOf: ["--cookies-from-browser", c])
        }

        // ffmpeg 路径
        if let ff = config.ffmpegLocation ?? BinaryResolver.ffmpegURL() {
            args.append(contentsOf: ["--ffmpeg-location", ff.deletingLastPathComponent().path])
        }

        args.append(url)

        let outputURL: URL
        do {
            outputURL = try await runYtdlp(task: task, ytdlp: ytdlp, args: args)
        } catch let err as EngineError {
            task.status = .failed(err.localizedDescription)
            throw err
        } catch {
            task.status = .failed(error.localizedDescription)
            throw EngineError.downloadFailed(error.localizedDescription)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            task.status = .failed("输出文件不存在")
            throw EngineError.downloadFailed("输出文件不存在: \(outputURL.path)")
        }

        task.status = .downloaded(outputURL)
        task.progress = 1.0
        task.downloadFinishedAt = Date()
        task.outputFileURL = outputURL

        Logger.download.info("下载完成", metadata: ["output": outputURL.path, "size": fileSize(outputURL)])
        return outputURL
    }

    // MARK: - 元信息

    private struct Metadata { let title: String?; let uploader: String?; let duration: TimeInterval?; let thumbnail: String? }

    private func resolveMetadata(url: String, ytdlp: URL, cookie: CookieSource) async throws -> Metadata {
        var args = ["--no-playlist", "--skip-download",
                    "--print", "%(title)s⟦|⟧%(uploader,channel)s⟦|⟧%(duration)s⟦|⟧%(thumbnail)s"]
        args.append(contentsOf: Self.siteHeaders(for: url))
        if let c = cookie.ytdlpValue { args.append(contentsOf: ["--cookies-from-browser", c]) }
        args.append(url)

        Logger.download.info("元信息 args", metadata: ["args": args.joined(separator: " ")])
        let result = try await runProcessCollecting(executable: ytdlp, args: args, timeoutSec: 90)
        if result.exitCode != 0 {
            Logger.download.warn("元信息 exit=\(result.exitCode) stderr: \(String(result.stderr.prefix(800)))")
        }
        let firstLine = result.stdout.split(separator: "\n").first(where: { !$0.isEmpty }).map(String.init) ?? ""
        guard !firstLine.isEmpty else { throw EngineError.parseFailed }

        let parts = firstLine.components(separatedBy: "⟦|⟧")
        func clean(_ s: String?) -> String? {
            guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "NA" else { return nil }
            return s
        }
        return Metadata(
            title: clean(parts.count > 0 ? parts[0] : nil),
            uploader: clean(parts.count > 1 ? parts[1] : nil),
            duration: clean(parts.count > 2 ? parts[2] : nil).flatMap { TimeInterval($0) },
            thumbnail: clean(parts.count > 3 ? parts[3] : nil)
        )
    }

    // MARK: - 实际下载（流式解析进度）

    private func runYtdlp(task: UniTask, ytdlp: URL, args: [String]) async throws -> URL {
        Logger.download.info("─── 任务开始 ───", metadata: ["url": task.sourceURL ?? "", "args": args.joined(separator: " ")])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let proc = Process()
            proc.executableURL = ytdlp
            proc.arguments = args
            // 确保子进程能找到 ffmpeg、python 等
            var env = ProcessInfo.processInfo.environment
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = (env["PATH"].map { "\(extraPath):\($0)" }) ?? extraPath
            proc.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            var stdoutBuffer = ""
            var stderrBuffer = ""
            var finalPath: String?

            outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { return }
                guard let s = String(data: data, encoding: .utf8) else { return }
                stdoutBuffer += s
                while let nl = stdoutBuffer.firstIndex(of: "\n") {
                    let line = String(stdoutBuffer[..<nl])
                    stdoutBuffer.removeSubrange(...nl)
                    if !line.isEmpty && !line.contains("[download]") {
                        Logger.download.info("OUT: \(line)")
                    } else if line.contains("[download]") && (line.contains("Destination") || line.contains("100%") || line.contains("has already been downloaded")) {
                        Logger.download.info("OUT: \(line)")
                    }
                    Task { @MainActor in
                        self?.parseProgressLine(line, task: task)
                        if let path = Self.parseFilepath(line) { finalPath = path }
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let s = String(data: data, encoding: .utf8) {
                    stderrBuffer += s
                    for line in s.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty {
                        Logger.download.info("ERR: \(line)")
                    }
                }
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    Logger.download.info("退出码: \(p.terminationStatus) reason=\(p.terminationReason.rawValue) FILEPATH=\(finalPath ?? "<nil>")")
                    if p.terminationStatus == 0, let path = finalPath, FileManager.default.fileExists(atPath: path) {
                        cont.resume(returning: URL(fileURLWithPath: path))
                    } else if p.terminationStatus == 0 {
                        // 退出 0 但没拿到 FILEPATH（典型：已存在的视频）
                        if let existing = Self.parseAlreadyDownloaded(stdout: stdoutBuffer) {
                            Logger.download.warn("文件已存在: \(existing)")
                            cont.resume(returning: URL(fileURLWithPath: existing))
                        } else {
                            Logger.download.error("退出 0 但未找到输出文件。stdout 尾部: \(String(stdoutBuffer.suffix(500)))")
                            cont.resume(throwing: EngineError.downloadFailed("yt-dlp 正常退出但未找到输出文件，请查看日志：~/Library/Logs/AudioNote/"))
                        }
                    } else if p.terminationReason == .uncaughtSignal {
                        Logger.download.warn("被信号终止（取消）")
                        cont.resume(throwing: EngineError.cancelled)
                    } else {
                        let msg = Self.summarizeError(stderr: stderrBuffer, stdout: stdoutBuffer)
                        Logger.download.error("失败: \(msg)")
                        cont.resume(throwing: EngineError.downloadFailed(msg))
                    }
                }
            }

            task.process = proc
            do { try proc.run() } catch {
                cont.resume(throwing: EngineError.downloadFailed(error.localizedDescription))
            }
        }
    }

    /// 解析单行 yt-dlp 进度
    /// 形如：[download]  42.3% of   12.34MiB at  2.10MiB/s ETA 00:32
    private func parseProgressLine(_ line: String, task: UniTask) {
        guard line.contains("[download]") else { return }
        let pct = Self.match(line, pattern: #"(\d+(?:\.\d+)?)%"#)
        let size = Self.match(line, pattern: #"of\s+~?\s*([0-9.]+\s*[KMG]?i?B)"#)
        let speed = Self.match(line, pattern: #"at\s+([0-9.]+\s*[KMG]?i?B/s)"#)
        let eta = Self.match(line, pattern: #"ETA\s+([0-9:]+)"#)

        if let p = pct, let val = Double(p) { task.progress = val / 100.0 }
        if let s = size { task.totalSize = s }
        if let sp = speed { task.speed = sp }
        if let e = eta { task.eta = e }
    }

    private static func parseFilepath(_ line: String) -> String? {
        if line.hasPrefix("FILEPATH=") {
            return String(line.dropFirst("FILEPATH=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// 解析 "[download] xxx has already been downloaded" 行的文件路径
    private static func parseAlreadyDownloaded(stdout: String) -> String? {
        for raw in stdout.split(separator: "\n") {
            let line = String(raw)
            if line.contains("has already been downloaded") {
                if let r1 = line.range(of: "[download]"),
                   let r2 = line.range(of: "has already been downloaded") {
                    let start = line.index(r1.upperBound, offsetBy: 0)
                    let end = r2.lowerBound
                    if start < end {
                        let path = String(line[start..<end]).trimmingCharacters(in: .whitespaces)
                        if FileManager.default.fileExists(atPath: path) { return path }
                    }
                }
            }
            if line.contains("[download] Destination:") {
                if let r = line.range(of: "Destination:") {
                    let path = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if FileManager.default.fileExists(atPath: path) { return path }
                }
            }
        }
        return nil
    }

    private static func match(_ s: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// 生成「MMDDHHMMSS」格式时间戳（本地时区，精确到秒，10 位）
    private static func makeTimestamp(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMddHHmmss"
        return f.string(from: date)
    }

    // MARK: - 站点 headers

    /// 站点特定的 HTTP headers（提升解析成功率）
    public static func siteHeaders(for url: String) -> [String] {
        let lower = url.lowercased()
        let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        var args: [String] = []
        if lower.contains("bilibili.com") || lower.contains("b23.tv") {
            args.append(contentsOf: ["--user-agent", chromeUA])
            args.append(contentsOf: ["--referer", "https://www.bilibili.com"])
        } else if lower.contains("douyin.com") || lower.contains("iesdouyin.com") {
            args.append(contentsOf: ["--user-agent", chromeUA])
            args.append(contentsOf: ["--referer", "https://www.douyin.com"])
        } else if lower.contains("weibo.com") || lower.contains("weibo.cn") {
            args.append(contentsOf: ["--user-agent", chromeUA])
            args.append(contentsOf: ["--referer", "https://weibo.com"])
        } else if lower.contains("xiaohongshu.com") || lower.contains("xhslink.com") {
            args.append(contentsOf: ["--user-agent", chromeUA])
            args.append(contentsOf: ["--referer", "https://www.xiaohongshu.com"])
        }
        return args
    }

    // MARK: - 错误归纳

    private static func summarizeError(stderr: String, stdout: String) -> String {
        let combined = stderr + "\n" + stdout
        let isBili = combined.contains("[BiliBili]") || combined.contains("[bilibili]")

        if combined.contains("WRONG_VERSION_NUMBER") || combined.contains("SSL: WRONG_VERSION_NUMBER") {
            return "网络 SSL 协议错误。可能是代理/网络问题，建议检查代理设置或换网络重试"
        }
        if combined.contains("CERTIFICATE_VERIFY_FAILED") {
            return "SSL 证书验证失败。请检查系统时间或代理设置"
        }
        if combined.contains("Connection reset by peer") || combined.contains("Connection refused") {
            return "网络连接被重置，请检查网络或代理后重试"
        }
        if combined.contains("Giving up after") && combined.contains("retries") {
            if combined.contains("WRONG_VERSION_NUMBER") || combined.contains("SSL") {
                return "网络 SSL 错误，已重试 10 次仍失败。建议：① 关闭/调整代理 ② 检查网络 ③ 稍后重试"
            }
            return "网络连接持续失败（已重试多次）。建议检查网络或代理后重试"
        }

        let lines = combined.split(separator: "\n")
        for line in lines.reversed() {
            let str = String(line)
            if str.contains("ERROR:") || str.contains("error:") {
                if str.contains("Unsupported URL") { return "暂不支持该网站" }
                if isBili, str.contains("HTTP Error 403") || str.contains("HTTP Error 412") {
                    return "B 站拒绝匿名访问。请在『设置 → 下载』中选择已登录 B 站的浏览器（Chrome / Edge / Safari）后重试"
                }
                if str.contains("HTTP Error 403") { return "服务器拒绝访问（403），可能需要登录态。请在设置中选择已登录该站的浏览器" }
                if str.contains("HTTP Error 412") { return "请求被反爬拦截（412）。请在设置中选择已登录的浏览器以使用其 Cookie" }
                if str.contains("HTTP Error 404") { return "视频不存在或已删除（404）" }
                if str.contains("Sign in") || str.contains("login") || str.contains("登录") {
                    return "需要登录态，请在设置中选择已登录的浏览器 Cookie"
                }
                if str.contains("DRM") { return "受 DRM 保护，无法下载" }
                if str.contains("members-only") || str.contains("Private video") {
                    return "私密/会员专享内容，需要登录态。请在设置中选择已登录的浏览器"
                }
                if str.contains("Unable to download webpage") { return "网络错误，无法访问该 URL" }
                if let r = str.range(of: "ERROR:") {
                    let tail = String(str[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    return String(tail.prefix(200))
                }
                return String(str.prefix(200))
            }
        }
        return "下载失败（未知错误）"
    }

    // MARK: - 进程辅助

    private struct ProcessResult { let exitCode: Int32; let stdout: String; let stderr: String }

    private func runProcessCollecting(executable: URL, args: [String], timeoutSec: Int) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ProcessResult, Error>) in
            let proc = Process()
            proc.executableURL = executable
            proc.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            proc.environment = env

            let outPipe = Pipe(); let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            do { try proc.run() } catch {
                cont.resume(throwing: error); return
            }

            let timeoutTask = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSec), execute: timeoutTask)

            DispatchQueue.global().async {
                proc.waitUntilExit()
                timeoutTask.cancel()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                cont.resume(returning: ProcessResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
            }
        }
    }

    private func fileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return "unknown" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
