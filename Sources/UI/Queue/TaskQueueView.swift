import SwiftUI

/// 统一任务队列 — 全局看板，四状态快速筛选
struct TaskQueueView: View {
    @EnvironmentObject var scheduler: TaskScheduler
    @State private var filter: QueueFilter = .all
    @State private var searchText: String = ""

    enum QueueFilter: String, CaseIterable { case all = "全部", downloading = "下载中", transcribing = "转写中", completed = "已完成", failed = "失败" }

    var filteredTasks: [UniTask] {
        var tasks: [UniTask]
        switch filter {
        case .all:          tasks = scheduler.allTasks
        case .downloading:  tasks = scheduler.downloadingTasks
        case .transcribing: tasks = scheduler.transcribingTasks
        case .completed:    tasks = scheduler.completedTasks
        case .failed:       tasks = scheduler.failedTasks
        }
        if searchText.isEmpty { return tasks }
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 筛选栏
            HStack {
                Picker("", selection: $filter) {
                    ForEach(QueueFilter.allCases, id: \.self) { f in
                        Text("\(f.rawValue) (\(countFor(f)))").tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Spacer()

                if !scheduler.activeTasks.isEmpty {
                    Button("暂停全部") { scheduler.isPausedGlobally = true }.buttonStyle(.bordered).controlSize(.small)
                }
                Button("清空已完成") { scheduler.clearCompleted() }.buttonStyle(.bordered).controlSize(.small)
                    .disabled(scheduler.completedTasks.isEmpty && scheduler.failedTasks.isEmpty)
            }
            .padding(DS.Spacing.md)

            Divider()

            // 列表
            if filteredTasks.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.quaternary)
                    Text("暂无任务").font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredTasks) { task in
                        QueueTaskRow(task: task, scheduler: scheduler)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                            .contextMenu {
                                if task.status.canPause { Button("暂停") { scheduler.pause(task) } }
                                if task.status.canResume { Button("继续") { scheduler.resume(task) } }
                                if task.status.canRetry { Button("重试") { scheduler.retry(task) } }
                                if case .downloaded = task.status { Button("跳过转写") { scheduler.skipTranscribe(task) } }
                                Divider()
                                Button("置顶") { scheduler.setPriority(task, priority: 10) }
                                if task.status.canCancel {
                                    Button("取消", role: .destructive) { scheduler.cancel(task) }
                                }
                                if task.status.canRemove {
                                    Button("移除", role: .destructive) { scheduler.remove(task) }
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }

            // 底部状态栏
            Divider()
            HStack {
                Label("共 \(scheduler.allTasks.count) 个任务", systemImage: "list.bullet")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("并发下载: \(scheduler.maxConcurrentDownloads)").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Spacing.lg).padding(.vertical, 6)
        }
        .background(DS.Surface.windowBg)
    }

    private func countFor(_ f: QueueFilter) -> Int {
        switch f {
        case .all: return scheduler.allTasks.count
        case .downloading: return scheduler.downloadingTasks.count
        case .transcribing: return scheduler.transcribingTasks.count
        case .completed: return scheduler.completedTasks.count
        case .failed: return scheduler.failedTasks.count
        }
    }
}

struct QueueTaskRow: View {
    @ObservedObject var task: UniTask
    let scheduler: TaskScheduler

    /// 每秒刷新一次「现在」，让进行中任务的 elapsed/ETA 文本能跟着走
    @State private var nowTick: Date = Date()
    private let tickTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                // 第一行：标题 + 类型 badge + 状态
                HStack(spacing: 6) {
                    Text(task.displayTitle)
                        .font(.system(size: DS.Font.primary, weight: .medium))
                        .lineLimit(1)
                    DSBadge(text: task.inputType.rawValue, tint: .secondary)
                    if task.priority >= 10 {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 8)
                    Text(task.status.displayText)
                        .font(.system(size: DS.Font.secondary, weight: .medium))
                        .foregroundStyle(statusColor)
                }

                // 第二行：下载阶段 + 转写阶段双行进度
                stageInfoRow
            }

            // 操作按钮组（常驻可见）
            actionButtons
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onReceive(tickTimer) { now in
            // 仅运行中任务需要持续刷新
            if task.status.isRunning { nowTick = now }
        }
    }

    // MARK: - 阶段信息（下载 / 转写）

    @ViewBuilder
    private var stageInfoRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 下载阶段
            if task.downloadStartedAt != nil {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 11)).foregroundStyle(DS.Status.downloading)
                    if case .downloading = task.status {
                        Text("\(Int(task.progress * 100))%")
                            .font(.system(size: DS.Font.micro, weight: .semibold))
                            .foregroundStyle(DS.Status.downloading)
                        DSProgressBar(value: task.progress, tint: DS.Status.downloading).frame(width: 100)
                        if !task.speed.isEmpty {
                            Text(task.speed).font(.system(size: DS.Font.micro)).foregroundStyle(.secondary)
                        }
                    }
                    if let e = task.downloadElapsedSeconds(now: nowTick) {
                        Text("耗时 \(UniTask.formatElapsed(e))").font(.system(size: DS.Font.micro)).foregroundStyle(.tertiary)
                    }
                    if case .downloading = task.status, let r = task.estimatedRemainingSeconds(now: nowTick) {
                        Text("· 剩余 ~\(UniTask.formatElapsed(r))").font(.system(size: DS.Font.micro)).foregroundStyle(.tertiary)
                    }
                }
            }

            // 转写阶段
            if task.transcribeStartedAt != nil {
                HStack(spacing: 8) {
                    Image(systemName: "text.quote").font(.system(size: 11)).foregroundStyle(DS.Status.transcribing)
                    if case .transcribing = task.status {
                        Text("\(Int(task.progress * 100))%")
                            .font(.system(size: DS.Font.micro, weight: .semibold))
                            .foregroundStyle(DS.Status.transcribing)
                        DSProgressBar(value: task.progress, tint: DS.Status.transcribing).frame(width: 100)
                    }
                    if let e = task.transcribeElapsedSeconds(now: nowTick) {
                        Text("耗时 \(UniTask.formatElapsed(e))").font(.system(size: DS.Font.micro)).foregroundStyle(.tertiary)
                    }
                    if case .transcribing = task.status, let r = task.estimatedRemainingSeconds(now: nowTick) {
                        Text("· 剩余 ~\(UniTask.formatElapsed(r))").font(.system(size: DS.Font.micro)).foregroundStyle(.tertiary)
                    }
                    if task.transcribeCompletedSegments > 0, case .transcribing = task.status {
                        Text("· 已落盘 \(task.transcribeCompletedSegments) 段")
                            .font(.system(size: DS.Font.micro)).foregroundStyle(.tertiary)
                    }
                }
            }

            // 没有任何阶段时间（pending / cancelled / recording 等）的兜底
            if task.downloadStartedAt == nil && task.transcribeStartedAt == nil {
                if case .recording = task.status {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(DS.Status.recording)
                        Text("录制中").font(.system(size: DS.Font.micro)).foregroundStyle(.secondary)
                    }
                } else if let e = task.elapsedSeconds(now: nowTick) {
                    Text(UniTask.formatElapsed(e)).font(.system(size: DS.Font.micro)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 操作按钮组（常驻可见）

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            // 置顶（非终态显示）
            if !task.status.isTerminal {
                iconButton(
                    icon: task.priority >= 10 ? "pin.slash" : "pin",
                    help: task.priority >= 10 ? "取消置顶" : "置顶",
                    color: task.priority >= 10 ? .orange : .secondary
                ) {
                    scheduler.setPriority(task, priority: task.priority >= 10 ? 0 : 10)
                }
            }

            // 暂停 / 继续 / 重试
            if task.status.canPause {
                iconButton(icon: "pause.circle", help: "暂停", color: .blue) {
                    scheduler.pause(task)
                }
            }
            if task.status.canResume {
                iconButton(icon: "play.circle", help: "继续", color: .green) {
                    scheduler.resume(task)
                }
            }
            if task.status.canRetry {
                iconButton(icon: "arrow.clockwise.circle", help: "重试", color: .blue) {
                    scheduler.retry(task)
                }
            }

            // 取消（运行中/暂停） / 移除（终态）
            if task.status.canCancel {
                iconButton(icon: "stop.circle", help: "取消", color: .red) {
                    scheduler.cancel(task)
                }
            } else if task.status.canRemove {
                iconButton(icon: "xmark.circle", help: "从列表移除", color: .secondary) {
                    scheduler.remove(task)
                }
            }
        }
        .padding(.top, 1)
    }

    private func iconButton(icon: String, help: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 状态图标

    private var statusIcon: some View {
        Image(systemName: {
            switch task.status {
            case .pending: return "circle"
            case .resolving: return "magnifyingglass.circle"
            case .downloading: return "arrow.down.circle.fill"
            case .downloadingPaused: return "pause.circle"
            case .downloaded: return "checkmark.circle"
            case .recording: return "mic.circle.fill"
            case .extracting: return "gearshape.2"
            case .transcribing: return "text.quote"
            case .transcribingPaused: return "pause.circle"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            case .cancelled: return "xmark.circle"
            case .skippedTranscribe: return "checkmark.circle"
            }
        }()).font(.system(size: 20)).foregroundStyle(statusColor).frame(width: 28)
    }

    private var statusColor: Color {
        if case .downloading = task.status { return DS.Status.downloading }
        if case .transcribing = task.status { return DS.Status.transcribing }
        if case .completed = task.status { return DS.Status.success }
        if case .failed = task.status { return DS.Status.failure }
        if case .recording = task.status { return DS.Status.recording }
        if case .downloadingPaused = task.status { return .orange }
        if case .transcribingPaused = task.status { return .orange }
        return .secondary
    }
}
