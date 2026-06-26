import Foundation

/// 依赖管理与首次启动检查清单
///
/// AudioNote 依赖分层：
/// L0 — macOS 系统框架 (SwiftUI, AVFoundation, Combine) — 总是可用
/// L1 — 系统二进制 (python3, pip3) — macOS 自带/需 Homebrew
/// L2 — Python 包 (sherpa-onnx, numpy, yt-dlp) — pip install
/// L3 — 模型文件 (sherpa-onnx ~500MB) — 首次下载
/// L4 — 外部二进制 (ffmpeg, BlackHole) — bundle 或系统
///
/// 分发策略:
///   - ffmpeg: bundle 到 .app/Contents/Resources/vendor/ffmpeg (约 48MB)
///   - yt-dlp: 通过 pip 确保安装（轻量 Python 包）
///   - python3: 依赖系统 python3（macOS 普遍自带 3.9+）
///   - sherpa-onnx + numpy: pip install 首次启动自动安装
///   - 模型: 首次转写时自动下载到 ~/Library/Application Support/AudioNote/models/
///   - BlackHole: 弹窗引导手动安装（无法自动）
@MainActor
final class DependencyManager: ObservableObject {
    static let shared = DependencyManager()
    private init() {}

    @Published var isChecking: Bool = false
    @Published var checkResults: [DependencyCheck] = []
    @Published var allReady: Bool = false

    // MARK: - 依赖项定义

    struct DependencyCheck: Identifiable {
        let id: String
        let name: String
        let description: String
        let level: CheckLevel
        var status: CheckStatus = .pending
        var detail: String = ""

        enum CheckLevel: String {
            case critical  // 没有则完全无法使用
            case recommended // 没有则部分功能不可用
            case optional  // 纯体验增强
        }

        enum CheckStatus {
            case pending, checking, ok, warning(String), error(String)
            var icon: String {
                switch self {
                case .pending:  return "circle"
                case .checking: return "ellipsis.circle"
                case .ok:       return "checkmark.circle.fill"
                case .warning:  return "exclamationmark.triangle.fill"
                case .error:    return "xmark.circle.fill"
                }
            }
            var color: String {
                switch self {
                case .pending:  return "secondary"
                case .checking: return "blue"
                case .ok:       return "green"
                case .warning:  return "orange"
                case .error:    return "red"
                }
            }
        }
    }

    // MARK: - 检查清单

    func buildChecklist() -> [DependencyCheck] {
        return [
            DependencyCheck(id: "ffmpeg", name: "ffmpeg", description: "音视频处理核心", level: .critical),
            DependencyCheck(id: "python3", name: "Python 3", description: "Python 运行时 (3.9+)", level: .critical),
            DependencyCheck(id: "pip", name: "pip3", description: "Python 包管理", level: .critical),
            DependencyCheck(id: "ytdlp", name: "yt-dlp", description: "视频网站解析下载", level: .critical),
            DependencyCheck(id: "sherpa", name: "sherpa-onnx", description: "离线 ASR 引擎 (Python)", level: .critical),
            DependencyCheck(id: "numpy", name: "numpy", description: "科学计算库", level: .critical),
            DependencyCheck(id: "model", name: "ASR 模型文件", description: "SenseVoice 转写模型 (~500MB)", level: .critical),
            DependencyCheck(id: "blackhole", name: "BlackHole", description: "系统音频环回录制", level: .recommended),
            DependencyCheck(id: "disk", name: "磁盘空间", description: "推荐 ≥2GB 可用空间", level: .recommended),
        ]
    }

    // MARK: - 执行检查

    func runAllChecks() async {
        isChecking = true
        var results = buildChecklist()

        for i in results.indices {
            results[i].status = .checking
            checkResults = results

            switch results[i].id {
            case "ffmpeg":
                if BinaryResolver.ffmpegURL() != nil {
                    results[i].status = .ok
                    results[i].detail = "已就绪"
                } else {
                    // Bundle ffmpeg 兜底
                    let vendorPath = Bundle.main.resourceURL?.appendingPathComponent("vendor/ffmpeg").path
                    if vendorPath.flatMap({ FileManager.default.isExecutableFile(atPath: $0) }) == true {
                        results[i].status = .ok
                        results[i].detail = "内置版本"
                    } else {
                        results[i].status = .error("请安装: brew install ffmpeg")
                    }
                }

            case "python3":
                if let py = BinaryResolver.python3URL() {
                    let ver = await getPythonVersion()
                    results[i].status = .ok
                    results[i].detail = "v\(ver)"
                    Logger.app.info("Python3 已找到", metadata: ["path": py.path, "version": ver])
                } else {
                    results[i].status = .error("macOS 未找到 python3")
                    Logger.app.error("Python3 未找到")
                }

            case "pip":
                if let py = BinaryResolver.python3URL() {
                    let ok = await checkPythonPackage(python: py, package: "pip")
                    results[i].status = ok ? .ok : .error("pip 不可用")
                } else {
                    results[i].status = .error("依赖 python3")
                }

            case "ytdlp":
                // yt-dlp 可以是系统二进制 (Homebrew) 或 Python 包，两者均有效
                if BinaryResolver.ytdlpURL() != nil {
                    results[i].status = .ok
                    results[i].detail = "已安装"
                } else if let py = BinaryResolver.python3URL() {
                    let ok = await checkPythonPackage(python: py, package: "yt_dlp")
                    if ok {
                        results[i].status = .ok
                        results[i].detail = "Python 包"
                    } else {
                        results[i].status = .warning("brew install yt-dlp 或 pip install yt-dlp")
                    }
                }

            case "sherpa":
                if let py = BinaryResolver.python3URL() {
                    let ok = await checkPythonPackage(python: py, package: "sherpa_onnx")
                    if ok {
                        results[i].status = .ok
                        results[i].detail = "已安装"
                    } else {
                        results[i].status = .warning("pip install sherpa-onnx")
                    }
                }

            case "numpy":
                if let py = BinaryResolver.python3URL() {
                    let ok = await checkPythonPackage(python: py, package: "numpy")
                    results[i].status = ok ? .ok : .warning("pip install numpy")
                }

            case "model":
                // 检查多个可能的模型路径
                let modelName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
                let candidates: [URL] = [
                    modelDirectory().appendingPathComponent(modelName),
                    FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".cache/sherpa-onnx-models/\(modelName)"),
                ]
                let found = candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
                if found {
                    results[i].status = .ok
                    results[i].detail = "已下载"
                } else {
                    results[i].status = .warning("首次使用需下载约500MB")
                }

            case "blackhole":
                // 实际检查 BlackHole 设备是否可用
                let devices = AudioCaptureEngine.shared.availableDevices
                if devices.contains(where: { $0.name.lowercased().contains("blackhole") }) {
                    results[i].status = .ok
                    results[i].detail = "已检测到"
                } else {
                    results[i].status = .warning("brew install blackhole-2ch")
                }

            case "disk":
                if let free = freeDiskSpace(), free > 2_000_000_000 {
                    let gb = Double(free) / 1_000_000_000
                    results[i].status = .ok
                    results[i].detail = String(format: "%.1f GB", gb)
                } else {
                    results[i].status = .warning("磁盘空间不足")
                }

            default:
                results[i].status = .ok
            }
        }

        checkResults = results
        isChecking = false

        // 判断整体就绪
        let criticals = results.filter { $0.level == .critical }
        allReady = criticals.allSatisfy { if case .ok = $0.status { return true }; return false }

        Logger.app.info("依赖检查完成", metadata: [
            "total": results.count,
            "ok": results.filter { if case .ok = $0.status { return true }; return false }.count,
            "allReady": allReady
        ])
    }

    // MARK: - 一键安装

    /// 安装 Python 包依赖 (yt-dlp, numpy, sherpa-onnx)
    func installPythonDependencies() async throws {
        guard let python3 = BinaryResolver.python3URL() else {
            throw DepError.missingDependency("python3")
        }

        Logger.app.info("开始安装 Python 依赖")

        // 确保 pip 可用
        let pipCheck = Process()
        pipCheck.executableURL = python3
        pipCheck.arguments = ["-m", "pip", "--version"]
        let pipPipe = Pipe()
        pipCheck.standardOutput = pipPipe
        pipCheck.standardError = Pipe()
        try pipCheck.run()
        pipCheck.waitUntilExit()

        guard pipCheck.terminationStatus == 0 else {
            throw DepError.missingDependency("pip")
        }

        // 安装包
        let packages = ["numpy", "sherpa-onnx", "yt-dlp"]
        for pkg in packages {
            Logger.app.info("pip install \(pkg)")
            let process = Process()
            process.executableURL = python3
            process.arguments = ["-m", "pip", "install", "--user", "--quiet", pkg]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                Logger.app.warn("pip install \(pkg) 退出码 \(process.terminationStatus)")
            }
        }

        Logger.app.info("Python 依赖安装完成")
    }

    /// 下载 sherpa-onnx 模型文件
    func downloadModel(progress: @escaping (Double) -> Void) async throws {
        let modelDir = modelDirectory()
        try? FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)

        let modelName = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
        let modelPath = modelDir.appendingPathComponent(modelName)

        if FileManager.default.fileExists(atPath: modelPath.path) {
            Logger.app.info("模型已存在，跳过下载")
            progress(1.0)
            return
        }

        // 如果系统缓存目录已有，创建软链
        let cachedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/sherpa-onnx-models/\(modelName)")
        if FileManager.default.fileExists(atPath: cachedPath.path) {
            Logger.app.info("使用系统缓存的模型")
            try FileManager.default.createSymbolicLink(at: modelPath, withDestinationURL: cachedPath)
            progress(1.0)
            return
        }

        Logger.app.info("开始下载模型 (~500MB)")
        // 使用 sherpa-onnx 内置下载逻辑
        let python3 = BinaryResolver.python3URL()!
        let script = """
        import sherpa_onnx
        import os
        os.environ['SHERPA_ONNX_HOME'] = '\(modelDir.path)'
        config = sherpa_onnx.OfflineRecognizerConfig(
            model='\(modelName)',
        )
        rec = sherpa_onnx.OfflineRecognizer(config)
        print('MODEL_READY')
        """

        let process = Process()
        process.executableURL = python3
        process.arguments = ["-c", script]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        progress(1.0)
        Logger.app.info("模型下载完成")
    }

    // MARK: - Private

    private func getPythonVersion() async -> String {
        guard let py = BinaryResolver.python3URL() else { return "?" }
        let process = Process()
        process.executableURL = py
        process.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit() } catch { return "?" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }

    private func checkPythonPackage(python: URL, package: String) async -> Bool {
        let process = Process()
        process.executableURL = python
        process.arguments = ["-c", "import \(package)"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"]
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            if !ok {
                let errData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile()
                let errMsg = errData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                Logger.app.warn("Python包检查失败", metadata: ["python": python.path, "package": package, "stderr": errMsg.prefix(100)])
            }
            return ok
        } catch {
            Logger.app.error("Python包检查异常", metadata: ["python": python.path, "package": package], error: error)
            return false
        }
    }

    func modelDirectory() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudioNote/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func freeDiskSpace() -> Int64? {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            return attrs[.systemFreeSize] as? Int64
        } catch { return nil }
    }

    enum DepError: LocalizedError {
        case missingDependency(String)
        var errorDescription: String? {
            if case .missingDependency(let n) = self { return "缺少依赖: \(n)" }
            return nil
        }
    }
}
