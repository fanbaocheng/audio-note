import Foundation
import Combine

/// 统一任务调度器 — 管理任务队列、并发控制、持久化
@MainActor
final class TaskScheduler: ObservableObject {
    static let shared = TaskScheduler()
    init() { loadPersisted() }

    @Published var allTasks: [UniTask] = []
    @Published var maxConcurrentDownloads: Int = 3
    @Published var isPausedGlobally: Bool = false

    /// 按状态筛选
    var downloadingTasks: [UniTask] {
        allTasks.filter { if case .downloading = $0.status { return true }; return false }
    }
    var transcribingTasks: [UniTask] {
        allTasks.filter { if case .transcribing = $0.status { return true }; return false }
    }
    var completedTasks: [UniTask] {
        allTasks.filter { if case .completed = $0.status { return true }; return false }
    }
    var failedTasks: [UniTask] {
        allTasks.filter { if case .failed = $0.status { return true }; return false }
    }
    var pendingTasks: [UniTask] {
        allTasks.filter { if case .pending = $0.status { return true }; return false }
    }
    var activeTasks: [UniTask] {
        allTasks.filter { $0.status.isRunning }
    }

    // MARK: - 任务操作

    func enqueue(_ task: UniTask) {
        Logger.scheduler.info("任务入队", metadata: ["id": task.id.uuidString.prefix(8), "type": task.inputType.rawValue, "title": task.title])
        allTasks.insert(task, at: 0)
        persist()
    }

    func cancel(_ task: UniTask) {
        Logger.scheduler.info("取消任务", metadata: ["id": task.id.uuidString.prefix(8)])
        task.process?.terminate()
        task.process = nil
        task.status = .cancelled
        task.finishedAt = Date()
        persist()
    }

    func pause(_ task: UniTask) {
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
    func resume(_ task: UniTask) {
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
    func remove(_ task: UniTask) {
        if let idx = allTasks.firstIndex(where: { $0.id == task.id }) {
            Logger.scheduler.info("移除任务", metadata: ["id": task.id.uuidString.prefix(8)])
            allTasks.remove(at: idx)
            persist()
        }
    }

    func retry(_ task: UniTask) {
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

    func skipTranscribe(_ task: UniTask) {
        if case .downloaded(let url) = task.status {
            Logger.scheduler.info("跳过转写", metadata: ["id": task.id.uuidString.prefix(8)])
            task.status = .skippedTranscribe(url)
            persist()
        }
    }

    func clearCompleted() {
        let before = allTasks.count
        allTasks.removeAll { $0.status.isTerminal }
        Logger.scheduler.info("清空已完成/失败任务", metadata: ["removed": before - allTasks.count])
        persist()
    }

    func setPriority(_ task: UniTask, priority: Int) {
        task.priority = min(10, max(0, priority))
        Logger.scheduler.info("调整优先级", metadata: ["id": task.id.uuidString.prefix(8), "priority": task.priority])
    }

    // MARK: - 任务提交

    /// 提交 URL 下载任务
    func enqueueDownload(_ task: UniTask) {
        enqueue(task)
        Task {
            await UnifiedPipeline.shared.processDownload(task: task)
        }
    }

    /// 提交录制转写
    func enqueueRecording(fileURL: URL) {
        let task = UniTask(inputType: .recording, sourceFilePath: fileURL.path)
        task.title = "录制 \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
        enqueue(task)
        Task {
            await UnifiedPipeline.shared.processRecording(task: task, fileURL: fileURL)
        }
    }

    /// 提交文件导入
    func enqueueImportOrRecording(fileURL: URL, type: InputType = .fileImport) {
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

    func persist() {
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
                sourceFilePath: snap.sourceFilePath
            )
            task.restore(from: snap)
            allTasks.append(task)
        }
    }
}
