import Foundation

// MARK: - 统一输入类型
enum InputType: String, Codable, CaseIterable {
    case urlDownload = "URL下载"
    case recording   = "声卡录制"
    case fileImport  = "本地导入"
}

// MARK: - 任务状态
enum TaskStatus: Equatable {
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

    var displayText: String {
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

    var isRunning: Bool {
        switch self {
        case .resolving, .downloading, .extracting, .transcribing, .recording: return true
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .skippedTranscribe: return true
        default: return false
        }
    }

    var canRetry: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    var canPause: Bool {
        switch self {
        case .downloading, .transcribing, .recording: return true
        default: return false
        }
    }

    /// 暂停态：UI 上提供「继续」按钮，下载任务恢复用 enqueue/retry，转写任务恢复利用 sidecar 重新启动
    var canResume: Bool {
        switch self {
        case .downloadingPaused, .transcribingPaused: return true
        default: return false
        }
    }

    /// 是否可取消（非终态都可取消，包括 paused）
    var canCancel: Bool {
        if isTerminal { return false }
        return true
    }

    /// 终态下 UI 行末按钮可显示"移除"
    var canRemove: Bool { isTerminal }
}

// MARK: - 下载模式
enum DownloadMode: String, Codable, CaseIterable {
    case video = "视频+音频"
    case audio = "仅音频"

    var iconName: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        }
    }
}

// MARK: - Cookie 来源
enum CookieSource: String, Codable, CaseIterable {
    case none, chrome, safari, firefox, edge, brave

    var label: String {
        switch self {
        case .none:    return "不使用 Cookie"
        case .chrome:  return "Chrome"
        case .safari:  return "Safari"
        case .firefox: return "Firefox"
        case .edge:    return "Edge"
        case .brave:   return "Brave"
        }
    }
    var ytdlpValue: String? {
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
final class UniTask: ObservableObject, Identifiable {
    let id: UUID
    let inputType: InputType
    let sourceURL: String?
    let sourceFilePath: String?
    let downloadMode: DownloadMode
    let createdAt: Date

    @Published var title: String = ""
    @Published var status: TaskStatus = .pending
    @Published var progress: Double = 0          // 0..1
    @Published var speed: String = ""
    @Published var eta: String = ""
    @Published var totalSize: String = ""
    @Published var outputFileURL: URL?           // 最终产物路径
    @Published var transcriptURL: URL?           // 转写 .txt 路径
    @Published var transcriptSRTURL: URL?        // 转写 .srt 路径
    @Published var transcriptCharCount: Int = 0
    @Published var errorMessage: String?
    @Published var autoTranscribe: Bool = true
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published var priority: Int = 0             // 0=默认, 10=置顶

    // 分阶段计时（便于 UI 分别展示下载耗时 / 转写耗时）
    @Published var downloadStartedAt: Date?
    @Published var downloadFinishedAt: Date?
    @Published var transcribeStartedAt: Date?
    @Published var transcribeFinishedAt: Date?

    // 转写断点续转：sidecar 文件路径（每段转写完后追加；下次启动转写时读取并跳过已完成段）
    @Published var transcribePartialURL: URL?
    @Published var transcribeCompletedSegments: Int = 0  // 已落盘的段数

    // 元数据
    @Published var duration: TimeInterval?
    @Published var uploader: String?
    @Published var thumbnailURL: URL?

    /// 关联的子进程（用于取消）
    var process: Process?

    init(
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

    var displayTitle: String {
        if !title.isEmpty, title != sourceURL { return title }
        return sourceURL ?? sourceFilePath?.components(separatedBy: "/").last ?? "未命名"
    }

    var displaySource: String {
        if let u = sourceURL { return u }
        if let f = sourceFilePath { return f }
        return "—"
    }

    func elapsedSeconds(now: Date = Date()) -> TimeInterval? {
        guard let start = startedAt else { return nil }
        let end = finishedAt ?? now
        return max(0, end.timeIntervalSince(start))
    }

    /// 下载阶段耗时（如果已开始）
    func downloadElapsedSeconds(now: Date = Date()) -> TimeInterval? {
        guard let start = downloadStartedAt else { return nil }
        let end = downloadFinishedAt ?? now
        return max(0, end.timeIntervalSince(start))
    }

    /// 转写阶段耗时（如果已开始）
    func transcribeElapsedSeconds(now: Date = Date()) -> TimeInterval? {
        guard let start = transcribeStartedAt else { return nil }
        let end = transcribeFinishedAt ?? now
        return max(0, end.timeIntervalSince(start))
    }

    /// 当前阶段的预估剩余时间（基于 progress 线性外推）
    func estimatedRemainingSeconds(now: Date = Date()) -> TimeInterval? {
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

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 持久化
    func snapshot() -> TaskSnapshot {
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

    func restore(from snapshot: TaskSnapshot) {
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
struct TaskSnapshot: Codable {
    enum StoredStatus: Codable {
        case pending, downloaded(URL), completed(URL), failed(String), cancelled, interrupted, skipped(URL)
    }

    let id: UUID
    let inputType: InputType
    let sourceURL: String?
    let sourceFilePath: String?
    let downloadMode: DownloadMode
    let createdAt: Date
    let title: String
    let statusSnapshot: StoredStatus
    let outputFileURL: URL?
    let transcriptURL: URL?
    let autoTranscribe: Bool
    let startedAt: Date?
    let finishedAt: Date?
}
