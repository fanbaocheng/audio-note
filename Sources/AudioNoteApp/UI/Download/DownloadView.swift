import SwiftUI
import AudioNoteCore

/// 下载中心 — URL 多行输入 + 任务列表
///
/// 注：UI 上只暴露"下载音频"一种模式（默认 `.audio`）。
/// 视频下载相关枚举值（`DownloadMode.videoAudio`）和 Engine 代码保留，
/// 以备后续加回视频下载选项时直接复用。
struct DownloadView: View {
    @EnvironmentObject var scheduler: TaskScheduler
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool
    @State private var lastSubmittedCount: Int = 0
    @State private var showSubmitToast: Bool = false

    // 当前 UI 固定走音频下载
    private let downloadMode: DownloadMode = .audio

    var body: some View {
        VStack(spacing: 0) {
            inputCard
                .padding(DS.Spacing.lg)

            // 提交反馈 toast / 引导
            if showSubmitToast {
                submitToast
                    .padding(.horizontal, DS.Spacing.lg)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Spacer(minLength: 0)
        }
        .background(DS.Surface.windowBg)
        .animation(.easeInOut(duration: 0.25), value: showSubmitToast)
    }

    // MARK: - 提交反馈 toast

    private var submitToast: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
            Text("已提交 \(lastSubmittedCount) 个任务到队列，可在『任务』标签查看进度")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            Spacer()
            Button {
                showSubmitToast = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(Color.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(Color.green.opacity(0.25), lineWidth: 0.5)
        )
    }

    // MARK: - 输入卡片

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            // 多行 URL 输入
            urlEditor

            // 辅助提示
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("支持 YouTube、B 站、抖音等平台 · 多行 URL 每行一个")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            // 底部操作栏
            actionBar
        }
        .padding(DS.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.Surface.controlBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .stroke(DS.Surface.separator.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: - URL 多行编辑器

    private var urlEditor: some View {
        ZStack(alignment: .topLeading) {
            // 背景容器
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(DS.Surface.textBg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md)
                        .stroke(DS.Surface.separator, lineWidth: 0.5)
                )

            // TextEditor 不支持原生 placeholder，用 ZStack 叠加
            if inputText.isEmpty {
                Text("粘贴视频页面 URL，支持批量多行…\nhttps://www.youtube.com/...\nhttps://www.bilibili.com/...")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $inputText)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .focused($isInputFocused)
        }
        .frame(height: 120)
    }

    // MARK: - 底部操作栏

    private var actionBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            // 左：导入音频文件（次要操作，输入侧）
            Button(action: pickAndImportFile) {
                Label("导入音频文件", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Spacer()

            // URL 计数提示
            if !urlCountText.isEmpty {
                Text(urlCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            // 右：下载并转写（主操作，右下角）
            Button(action: submitURLs) {
                Label("下载并转写", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private var urlCountText: String {
        let lines = inputText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if lines.isEmpty { return "" }
        if lines.count == 1 { return "1 个 URL" }
        return "\(lines.count) 个 URL"
    }

    // MARK: - 任务列表

    private var taskList: some View {
        let active = scheduler.allTasks.filter { t in
            if case .completed = t.status { return false }
            if case .failed = t.status { return false }
            if case .cancelled = t.status { return false }
            return true
        }

        return Group {
            if active.isEmpty {
                // 不再显示重复的空状态 placeholder（卡片本身已经是引导）
                Spacer().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(active) { task in
                        TaskRowView(task: task, onCancel: { scheduler.cancel(task) }, onRemove: {
                            if let idx = scheduler.allTasks.firstIndex(where: { $0.id == task.id }) {
                                scheduler.allTasks.remove(at: idx)
                                scheduler.persist()
                            }
                        })
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                            .contextMenu { taskContextMenu(task) }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 操作

    private func submitURLs() {
        let lines = inputText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        Logger.download.info("批量提交 URL, 数量: \(lines.count)")

        var submitted = 0
        for raw in lines {
            // 自动补全协议（用户常直接粘 bilibili.com/... 或 www.youtube.com/...）
            var url = raw
            if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
                // 看起来像域名/路径就补 https://，否则跳过
                if url.contains(".") && !url.contains(" ") {
                    url = "https://" + url
                    Logger.download.info("自动补全协议: \(raw) → \(url)")
                } else {
                    Logger.download.warn("跳过无效 URL: \(raw)")
                    continue
                }
            }
            let task = UniTask(inputType: .urlDownload, sourceURL: url, downloadMode: downloadMode)
            scheduler.enqueueDownload(task)
            submitted += 1
        }

        inputText = ""

        if submitted > 0 {
            lastSubmittedCount = submitted
            showSubmitToast = true
            // 3 秒后自动收起
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                if lastSubmittedCount == submitted {
                    showSubmitToast = false
                }
            }
        }
    }

    private func pickAndImportFile() {
        let panel = NSOpenPanel()
        panel.title = "选择音频或视频文件"
        panel.prompt = "导入并转写"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        let supportedExts = ["wav","mp3","m4a","aac","flac","ogg","opus","aiff","aif","wma","mp4","mov","mkv","webm","avi","flv"]
        if panel.runModal() == .OK, let url = panel.url {
            let ext = url.pathExtension.lowercased()
            guard supportedExts.contains(ext) else {
                Logger.download.warn("不支持的文件格式: .\(ext)")
                return
            }
            Logger.download.info("导入本地文件: \(url.path)")
            scheduler.enqueueImportOrRecording(fileURL: url)
            lastSubmittedCount = 1
            showSubmitToast = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                showSubmitToast = false
            }
        }
    }

    @ViewBuilder
    private func taskContextMenu(_ task: UniTask) -> some View {
        if task.status.canPause {
            Button("暂停") { scheduler.pause(task) }
        }
        if task.status.canRetry {
            Button("重试") { scheduler.retry(task) }
        }
        Divider()
        if case .downloaded = task.status {
            Button("跳过转写") { scheduler.skipTranscribe(task) }
        }
        Button("取消", role: .destructive) { scheduler.cancel(task) }
    }
}

// MARK: - 任务行

struct TaskRowView: View {
    @ObservedObject var task: UniTask
    var onCancel: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @State private var isHover: Bool = false

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            // 图标
            Image(systemName: iconName)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 28)

            // 信息
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle)
                    .font(.system(size: DS.Font.primary, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    DSBadge(text: task.inputType.rawValue, tint: .secondary)

                    if case .downloading = task.status {
                        Text(task.speed)
                            .font(.system(size: DS.Font.micro))
                            .foregroundStyle(.secondary)
                    }

                    if case .transcribing = task.status {
                        Text("\(Int(task.progress * 100))%")
                            .font(.system(size: DS.Font.micro))
                            .foregroundStyle(DS.Status.transcribing)
                    }

                    if let elapsed = task.elapsedSeconds() {
                        Text(UniTask.formatElapsed(elapsed))
                            .font(.system(size: DS.Font.micro))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // 进度条 / 状态文字
            if task.status.isRunning {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(task.status.displayText)
                        .font(.system(size: DS.Font.micro))
                        .foregroundStyle(iconColor)
                    DSProgressBar(value: task.progress, tint: iconColor)
                        .frame(width: 100)
                }
            } else {
                Text(task.status.displayText)
                    .font(.system(size: DS.Font.secondary))
                    .foregroundStyle(iconColor)
            }

            // 取消 / 删除按钮（hover 显示）
            actionButton
                .frame(width: 22)
                .opacity(isHover ? 1 : 0.35)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHover = hovering }
        }
        .background(DSTaskRowBg(
            tint: iconColor,
            isError: taskFailed
        ))
    }

    @ViewBuilder
    private var actionButton: some View {
        // 运行中：显示 stop 圆形按钮（取消并 cleanup）
        // 终态/等待：显示 trash 按钮（从列表移除）
        if task.status.isRunning {
            Button(action: { onCancel?() }) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消任务")
        } else {
            Button(action: { onRemove?() ?? onCancel?() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("从列表移除")
        }
    }

    private var taskFailed: Bool {
        if case .failed = task.status { return true }
        return false
    }

    private var iconName: String {
        if case .transcribing = task.status { return "text.quote" }
        if case .downloading = task.status { return "arrow.down.circle.fill" }
        if case .completed = task.status { return "checkmark.circle.fill" }
        if case .failed = task.status { return "xmark.circle.fill" }
        if case .cancelled = task.status { return "xmark.circle" }
        if case .recording = task.status { return "mic.circle.fill" }
        return "circle"
    }

    private var iconColor: Color {
        if case .transcribing = task.status { return DS.Status.transcribing }
        if case .downloading = task.status { return DS.Status.downloading }
        if case .completed = task.status { return DS.Status.success }
        if case .failed = task.status { return DS.Status.failure }
        if case .recording = task.status { return DS.Status.recording }
        if case .extracting = task.status { return DS.Status.warning }
        return .secondary
    }
}
