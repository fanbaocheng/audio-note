import Foundation

// MARK: - 统一输入类型
public enum InputType: String, Codable, CaseIterable {
    case urlDownload = "URL下载"
    case recording   = "声卡录制"
    case fileImport  = "本地导入"
}

// MARK: - 任务状态
public enum TaskStatus: Equatable {
    case pending                          // 等待下载
    case resolving                        // 解析元信息
    case downloading                      // 下载中
    case downloadingPaused                // 下载暂停
    case downloaded(URL)                  // 下载完成，等待转写
    case recording                        // 录制中
    case extracting                       // 音频抽取中（视频→音频）
    case transcribing                     // ASR 转写中
    case transcribingPaused               // 转写暂停
    case completed(URL)                   // 全部完成
    case failed(String)                   // 失败
    case cancelled                        // 已取消
    case skippedTranscribe(URL)           // 跳过转写（仅保留文件）

    public var displayText: String {
        switch self {
        case .pending:                return "等待中"
        case .resolving:              return "解析中"
        case .downloading:            return "下载中"
        case .downloadingPaused:      return "下载暂停"
        case .downloaded:             return "等待转写"
        case .recording:              return "录制中"
        case .extracting:             return "音频抽取中"
        case .transcribing:           return "转写中"
        case .transcribingPaused:     return "转写暂停"
        case .completed:              return "已完成"
        case .failed(let m):          return "失败: \(m)"
        case .cancelled:              return "已取消"
        case .skippedTranscribe:      return "已下载(未转写)"
        }
    }

    public var isRunning: Bool {
        switch self {
        case .resolving, .downloading, .extracting, .transcribing, .recording: return true
        default: return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .skippedTranscribe: return true
        default: return false
        }
    }

    public var canRetry: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    public var canPause: Bool {
        switch self {
        case .downloading, .transcribing, .recording: return true
        default: return false
        }
    }

    /// 暂停态：UI 上提供「继续」按钮，下载任务恢复用 enqueue/retry，转写任务恢复利用 sidecar 重新启动
    public var canResume: Bool {
        switch self {
        case .downloadingPaused, .transcribingPaused: return true
        default: return false
        }
    }

    /// 是否可取消（非终态都可取消，包括 paused）
    public var canCancel: Bool {
        if isTerminal { return false }
        return true
    }

    /// 终态下 UI 行末按钮可显示"移除"
    public var canRemove: Bool { isTerminal }
}

// MARK: - 下载模式
public enum DownloadMode: String, Codable, CaseIterable {
    case video = "视频+音频"
    case audio = "仅音频"

    public var iconName: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        }
    }
}

// MARK: - Cookie 来源
public enum CookieSource: String, Codable, CaseIterable {
    case none, chrome, safari, firefox, edge, brave

    public var label: String {
        switch self {
        case .none:    return "不使用 Cookie"
        case .chrome:  return "Chrome"
        case .safari:  return "Safari"
        case .firefox: return "Firefox"
        case .edge:    return "Edge"
        case .brave:   return "Brave"
        }
    }
    public var ytdlpValue: String? {
        switch self {
        case .none: return nil
        case .chrome: return "chrome"
        case .safari: return "safari"
        case .firefox: return "firefox"
        case .edge: return "edge"
        case .brave: return "brave"
        }
    }
}

// MARK: - 统一任务模型
public final class UniTask: ObservableObject, Identifiable {
    public let id: UUID
    public let inputType: InputType
    public let sourceURL: String?
    public let sourceFilePath: String?
    public let downloadMode: DownloadMode
    public let createdAt: Date

    @Published public var title: String = ""
    @Published public var status: TaskStatus = .pending
    @Published public var progress: Double = 0          // 0..1
    @Published public var speed: String = ""
    @Published public var eta: String = ""
    @Published public var totalSize: String = ""
    @Published public var outputFileURL: URL?           // 最终产物路径
    @Published public var transcriptURL: URL?           // 转写 .txt 路径
    @Published public var transcriptSRTURL: URL?        // 转写 .srt 路径
    @Published public var transcriptCharCount: Int = 0
    @Published public var errorMessage: String?
    @Published public var autoTranscribe: Bool = true
    @Published public var startedAt: Date?
    @Published public var finishedAt: Date?
    @Published public var priority: Int = 0             // 0=默认, 10=置顶

    // 分阶段计时（便于 UI 分别展示下载耗时 / 转写耗时）
    @Published public var downloadStartedAt: Date?
    @Published public var downloadFinishedAt: Date?
    @Published public var transcribeStartedAt: Date?
    @Published public var transcribeFinishedAt: Date?

    // 转写断点续转：sidecar 文件路径（每段转写完后追加；下次启动转写时读取并跳过已完成段）
    @Published public var transcribePartialURL: URL?
    @Published public var transcribeCompletedSegments: Int = 0  // 已落盘的段数

    // 元数据
    @Published public var duration: TimeInterval?
    @Published public var uploader: String?
    @Published public var thumbnailURL: URL?

    /// 关联的子进程（用于取消）
    public var process: Process?

    public init(
        inputType: InputType,
        sourceURL: String? = nil,
        sourceFilePath: String? = nil,
        downloadMode: DownloadMode = .audio,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.inputType = inputType
        self.sourceURL = sourceURL
        self.sourceFilePath = sourceFilePath
        self.downloadMode = downloadMode
        self.createdAt = createdAt
        self.title = sourceURL ?? sourceFilePath?.components(separatedBy: "/").last ?? "未命名任务"
    }

    public var displayTitle: String {
        if !title.isEmpty, title != sourceURL { return title }
        return sourceURL ?? sourceFilePath?.components(separatedBy: "/").last ?? "未命名"
    }

    public var displaySource: String {
        if let u = sourceURL { return u }
        if let f = sourceFilePath { return f }
        return "—"
    }

    public func elapsedSeconds(now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = finishedAt ?? now
        return max(0, end.timeIntervalSince(start))
    }

    /// 下载阶段耗时（如果已开始）
    public func downloadElapsedSeconds(now: Date = Date()) -> TimeInterval? {
        guard let start = downloadStartedAt else { return nil }
        let end = downloadFinishedAt ?? now
        return max(0, end.timeIntervalSince(start))
    }

    /// 转写阶段耗时（如果已开始）
    public func transcribeElapsedSeconds(now: Date = Date()) -> TimeInterval? {
        guard let start = transcribeStartedAt else { return nil }
        let end = transcribeFinishedAt ?? now
        return max(0, end.timeIntervalSince(start))
    }

    /// 当前阶段的预估剩余时间（基于 progress 线性外推）
    public func estimatedRemainingSeconds(now: Date = Date()) -> TimeInterval? {
        let start: Date?
        switch status {
        case .downloading:
            start = downloadStartedAt
        case .transcribing:
            start = transcribeStartedAt
        default:
            return nil
        }
        guard let s = start, progress > 0.03, progress < 1.0 else { return nil }
        let elapsed = now.timeIntervalSince(s)
        let remaining = elapsed * (1.0 - progress) / progress
        return max(1, remaining)
    }

    public static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 持久化
    public func snapshot() -> TaskSnapshot {
        return TaskSnapshot(
            id: id, inputType: inputType, sourceURL: sourceURL,
            sourceFilePath: sourceFilePath, downloadMode: downloadMode,
            createdAt: createdAt, title: title, statusSnapshot: statusSnapshot,
            outputFileURL: outputFileURL, transcriptURL: transcriptURL,
            autoTranscribe: autoTranscribe, startedAt: startedAt,
            finishedAt: finishedAt
        )
    }

    private var statusSnapshot: TaskSnapshot.StoredStatus {
        switch status {
        case .pending:            return .pending
        case .resolving, .downloading, .extracting: return .interrupted
        case .downloadingPaused:  return .interrupted
        case .downloaded(let u):  return .downloaded(u)
        case .recording:          return .interrupted
        case .transcribing, .transcribingPaused: return .interrupted
        case .completed(let u):   return .completed(u)
        case .failed(let m):      return .failed(m)
        case .cancelled:          return .cancelled
        case .skippedTranscribe(let u): return .skipped(u)
        }
    }

    public func restore(from snapshot: TaskSnapshot) {
        self.title = snapshot.title
        self.outputFileURL = snapshot.outputFileURL
        self.transcriptURL = snapshot.transcriptURL
        self.autoTranscribe = snapshot.autoTranscribe
        self.startedAt = snapshot.startedAt
        self.finishedAt = snapshot.finishedAt
        switch snapshot.statusSnapshot {
        case .pending:       self.status = .pending
        case .downloaded(let u): self.status = .downloaded(u)
        case .completed(let u):  self.status = .completed(u); progress = 1.0
        case .failed(let m):     self.status = .failed(m)
        case .cancelled:         self.status = .cancelled
        case .skipped(let u):    self.status = .skippedTranscribe(u); progress = 1.0
        case .interrupted:       self.status = .cancelled
        }
    }
}

// MARK: - 持久化快照
public struct TaskSnapshot: Codable {
    public enum StoredStatus: Codable {
        case pending, downloaded(URL), completed(URL), failed(String), cancelled, interrupted, skipped(URL)
    }

    public let id: UUID
    public let inputType: InputType
    public let sourceURL: String?
    public let sourceFilePath: String?
    public let downloadMode: DownloadMode
    public let createdAt: Date
    public let title: String
    public let statusSnapshot: StoredStatus
    public let outputFileURL: URL?
    public let transcriptURL: URL?
    public let autoTranscribe: Bool
    public let startedAt: Date?
    public let finishedAt: Date?
}
