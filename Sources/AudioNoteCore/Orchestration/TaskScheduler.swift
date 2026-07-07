import Foundation
import Combine

/// 统一任务调度器 — 管理任务队列、并发控制、持久化
@MainActor
public final class TaskScheduler: ObservableObject {
    public static let shared = TaskScheduler()
    public init() { loadPersisted() }

    @Published public var allTasks: [UniTask] = []
    @Published public var maxConcurrentDownloads: Int = 3
    @Published public var isPausedGlobally: Bool = false

    /// 按状态筛选
    public var downloadingTasks: [UniTask] {
        allTasks.filter { if case .downloading = $0.status { return true }; return false }
    }
    public var transcribingTasks: [UniTask] {
        allTasks.filter { if case .transcribing = $0.status { return true }; return false }
    }
    public var completedTasks: [UniTask] {
        allTasks.filter { if case .completed = $0.status { return true }; return false }
    }
    public var failedTasks: [UniTask] {
        allTasks.filter { if case .failed = $0.status { return true }; return false }
    }
    public var pendingTasks: [UniTask] {
        allTasks.filter { if case .pending = $0.status { return true }; return false }
    }
    public var activeTasks: [UniTask] {
        allTasks.filter { $0.status.isRunning }
    }

    // MARK: - 任务操作

    public func enqueue(_ task: UniTask) {
        Logger.scheduler.info("任务入队", metadata: ["id": task.id.uuidString.prefix(8), "type": task.inputType.rawValue, "title": task.title])
        allTasks.insert(task, at: 0)
        persist()
    }

    public func cancel(_ task: UniTask) {
        Logger.scheduler.info("取消任务", metadata: ["id": task.id.uuidString.prefix(8)])
        task.process?.terminate()
        task.process = nil
        task.status = .cancelled
        task.finishedAt = Date()
        persist()
    }

    public func pause(_ task: UniTask) {
        if case .downloading = task.status {
            task.status = .downloadingPaused
            task.process?.terminate()
            task.process = nil
        } else if case .transcribing = task.status {
            task.status = .transcribingPaused
            task.process?.terminate()
            task.process = nil
        }
        Logger.scheduler.info("暂停任务", metadata: ["id": task.id.uuidString.prefix(8)])
        persist()
    }

    /// 从暂停状态继续。下载暂停 → 重新下载；转写暂停 → 重新启动 ASR（会通过 sidecar 自动断点续转）
    public func resume(_ task: UniTask) {
        Logger.scheduler.info("继续任务", metadata: ["id": task.id.uuidString.prefix(8), "from": task.status.displayText])
        switch task.status {
        case .downloadingPaused:
            // 重新下载（yt-dlp 自带断点续传 .part 文件，会自动续）
            task.status = .pending
            task.process = nil
            Task { await UnifiedPipeline.shared.processDownload(task: task) }
        case .transcribingPaused:
            // 重新启动转写：ASRService 读取 sidecar 自动跳过已完成段
            task.status = .pending
            task.process = nil
            // 取决于任务类型路由
            if case .urlDownload = task.inputType {
                Task { await UnifiedPipeline.shared.processDownload(task: task) }
            } else if let path = task.sourceFilePath {
                let fileURL = URL(fileURLWithPath: path)
                if task.inputType == .recording {
                    Task { await UnifiedPipeline.shared.processRecording(task: task, fileURL: fileURL) }
                } else {
                    Task { await UnifiedPipeline.shared.processFileImport(task: task, fileURL: fileURL) }
                }
            }
        default:
            return
        }
        persist()
    }

    /// 从列表移除（仅终态任务，运行中任务请用 cancel）
    public func remove(_ task: UniTask) {
        if let idx = allTasks.firstIndex(where: { $0.id == task.id }) {
            Logger.scheduler.info("移除任务", metadata: ["id": task.id.uuidString.prefix(8)])
            allTasks.remove(at: idx)
            persist()
        }
    }

    public func retry(_ task: UniTask) {
        Logger.scheduler.info("重试任务", metadata: ["id": task.id.uuidString.prefix(8)])

        switch task.inputType {
        case .urlDownload:
            guard task.sourceURL != nil else { return }
            // 原地复用同一个 task 对象（避免 retry 产生重复行）
            task.status = .pending
            task.progress = 0
            task.speed = ""
            task.eta = ""
            task.process = nil
            task.startedAt = nil
            task.finishedAt = nil
            persist()
            Task {
                await UnifiedPipeline.shared.processDownload(task: task)
            }

        case .recording, .fileImport:
            guard let path = task.sourceFilePath else { return }
            let fileURL = URL(fileURLWithPath: path)
            // 同样原地复用
            task.status = .pending
            task.progress = 0
            task.process = nil
            task.startedAt = nil
            task.finishedAt = nil
            persist()
            Task {
                if task.inputType == .recording {
                    await UnifiedPipeline.shared.processRecording(task: task, fileURL: fileURL)
                } else {
                    await UnifiedPipeline.shared.processFileImport(task: task, fileURL: fileURL)
                }
            }
        }
    }

    public func skipTranscribe(_ task: UniTask) {
        if case .downloaded(let url) = task.status {
            Logger.scheduler.info("跳过转写", metadata: ["id": task.id.uuidString.prefix(8)])
            task.status = .skippedTranscribe(url)
            persist()
        }
    }

    public func clearCompleted() {
        let before = allTasks.count
        allTasks.removeAll { $0.status.isTerminal }
        Logger.scheduler.info("清空已完成/失败任务", metadata: ["removed": before - allTasks.count])
        persist()
    }

    public func setPriority(_ task: UniTask, priority: Int) {
        task.priority = min(10, max(0, priority))
        Logger.scheduler.info("调整优先级", metadata: ["id": task.id.uuidString.prefix(8), "priority": task.priority])
    }

    // MARK: - 任务提交

    /// 提交 URL 下载任务
    public func enqueueDownload(_ task: UniTask) {
        enqueue(task)
        Task {
            await UnifiedPipeline.shared.processDownload(task: task)
        }
    }

    /// 提交录制转写
    /// - Parameter startImmediately: true（默认，GUI 用）立即起转写；false（CLI 用）只入队并返回 task，
    ///   由调用方自行 await 转写完成（CLI 必须在 exit 前 await，否则会被 exit 杀掉）。
    @discardableResult
    public func enqueueRecording(fileURL: URL, startImmediately: Bool = true) -> UniTask {
        let task = UniTask(inputType: .recording, sourceFilePath: fileURL.path)
        task.title = "录制 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
        enqueue(task)
        if startImmediately {
            Task {
                await UnifiedPipeline.shared.processRecording(task: task, fileURL: fileURL)
            }
        }
        return task
    }

    /// 提交文件导入
    public func enqueueImportOrRecording(fileURL: URL, type: InputType = .fileImport) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            Logger.scheduler.error("文件不存在", metadata: ["path": fileURL.path])
            return
        }
        let task = UniTask(inputType: type, sourceFilePath: fileURL.path)
        task.title = fileURL.deletingPathExtension().lastPathComponent
        enqueue(task)
        Task {
            await UnifiedPipeline.shared.processFileImport(task: task, fileURL: fileURL)
        }
    }

    // MARK: - 持久化

    private var persistURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AudioNote")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }

    public func persist() {
        let snapshots = allTasks.map { $0.snapshot() }
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: persistURL)
        }
    }

    private func loadPersisted() {
        guard let data = try? Data(contentsOf: persistURL),
              let snapshots = try? JSONDecoder().decode([TaskSnapshot].self, from: data) else {
            return
        }
        Logger.scheduler.info("恢复已持久化任务, 数量: \(snapshots.count)")
        for snap in snapshots {
            let task = UniTask(
                inputType: snap.inputType,
                sourceURL: snap.sourceURL,
                sourceFilePath: snap.sourceFilePath,
                downloadMode: snap.downloadMode,
                id: snap.id,
                createdAt: snap.createdAt
            )
            task.restore(from: snap)
            allTasks.append(task)
        }
    }

    // MARK: - 启动后自动续跑

    /// App 启动后调用：把上次未完成的任务（pending / downloaded / 被中断的 interrupted→pending）
    /// 重新跑起来，让下载/转写进度在 App 重启后自动续跑。
    /// 断点续传由各自的机制保证：下载靠 yt-dlp 的 .part 文件、转写靠 ASRService 的 *.partial.tsv sidecar。
    public func resumePersistedTasks() {
        let resumable = allTasks.filter { task in
            switch task.status {
            case .pending, .downloaded: return true
            default: return false
            }
        }
        for task in resumable {
            Logger.scheduler.info("重启后自动续跑任务", metadata: ["id": task.id.uuidString.prefix(8), "type": task.inputType.rawValue, "status": task.status.displayText])
            relaunch(task)
        }
    }

    private func relaunch(_ task: UniTask) {
        switch task.inputType {
        case .urlDownload:
            Task { await UnifiedPipeline.shared.processDownload(task: task) }
        case .recording:
            guard let p = task.sourceFilePath else { return }
            Task { await UnifiedPipeline.shared.processRecording(task: task, fileURL: URL(fileURLWithPath: p)) }
        case .fileImport:
            guard let p = task.sourceFilePath else { return }
            Task { await UnifiedPipeline.shared.processFileImport(task: task, fileURL: URL(fileURLWithPath: p)) }
        }
    }
}
