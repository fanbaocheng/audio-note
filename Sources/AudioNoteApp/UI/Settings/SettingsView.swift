import SwiftUI
import AudioNoteCore
import AppKit
import CoreAudio

struct SettingsView: View {
    @EnvironmentObject var recorder: AudioCaptureEngine
    @EnvironmentObject var scheduler: TaskScheduler
    @AppStorage("maxConcurrentDownloads", store: AppDefaults.shared) private var maxDL: Int = 3
    @AppStorage("AudioNote.downloadsDirectoryPath", store: AppDefaults.shared) private var downloadDir: String = ""
    @AppStorage(AudioCaptureEngine.recordingsDirectoryPathKey, store: AppDefaults.shared) private var recordingDir: String = ""
    @AppStorage("cookieSource", store: AppDefaults.shared) private var cookieSrc: String = CookieSource.none.rawValue

    @State private var dependencyResults: [DependencyManager.DependencyCheck] = []
    @State private var isCheckingDeps: Bool = false
    @State private var isInstalling: Bool = false
    @State private var allDepsReady: Bool = false

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gear") }
            recordingTab.tabItem { Label("录制", systemImage: "mic") }
            storageTab.tabItem { Label("存储", systemImage: "folder") }
            dependenciesTab.tabItem { Label("依赖", systemImage: "shippingbox") }
            aboutTab.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .scenePadding()
        .frame(minWidth: 520, minHeight: 440)
        .onAppear {
            maxDL = scheduler.maxConcurrentDownloads
            recorder.refreshDevices()
            // 应用持久化的路径到运行时引擎
            applyDownloadDirToEngine()
            applyCookieSourceToEngine()
            Task { await checkDependencies() }
        }
        .onChange(of: maxDL) { newVal in scheduler.maxConcurrentDownloads = newVal }
        .onChange(of: downloadDir) { _ in applyDownloadDirToEngine() }
        .onChange(of: cookieSrc) { _ in applyCookieSourceToEngine() }
    }

    private func applyDownloadDirToEngine() {
        let path = effectiveDownloadDir
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        DownloadEngine.shared.config.outputDir = url
        Logger.download.info("下载目录已更新", metadata: ["path": url.path])
    }

    private func applyCookieSourceToEngine() {
        if let src = CookieSource(rawValue: cookieSrc) {
            DownloadEngine.shared.config.cookieSource = src
            Logger.download.info("Cookie 源已更新", metadata: ["source": src.rawValue])
        }
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Stepper(value: $maxDL, in: 1...10) {
                    HStack {
                        Text("并发下载")
                        Spacer()
                        Text("\(maxDL)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Picker("Cookie 来源", selection: $cookieSrc) {
                    ForEach(CookieSource.allCases, id: \.rawValue) { s in
                        Text(s.label).tag(s.rawValue)
                    }
                }
            } header: {
                Text("下载")
            } footer: {
                Text("Cookie 用于下载需要登录的视频（B站会员、私享视频等）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 录制

    private var recordingTab: some View {
        Form {
            // 1. 录制模式
            Section {
                Picker("录制模式", selection: $recorder.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.iconName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("录制模式")
            } footer: {
                Text(modeFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 2. 设备选择
            Section {
                // 系统音频设备（systemAudio / mix 显示）
                if recorder.recordingMode == .systemAudio || recorder.recordingMode == .mix {
                    Picker("系统音频", selection: Binding<AudioDeviceID>(
                        get: { recorder.selectedSystemDevice?.id ?? 0 },
                        set: { newID in
                            recorder.selectedSystemDevice = recorder.availableSystemDevices.first { $0.id == newID }
                        }
                    )) {
                        if recorder.availableSystemDevices.isEmpty {
                            Text("未检测到环回设备").tag(AudioDeviceID(0))
                        } else {
                            ForEach(recorder.availableSystemDevices) { d in
                                Text(d.displayName).tag(d.id)
                            }
                        }
                    }
                }

                // 麦克风设备（microphone / mix 显示）
                if recorder.recordingMode == .microphone || recorder.recordingMode == .mix {
                    Picker("麦克风", selection: Binding<AudioDeviceID>(
                        get: { recorder.selectedMicDevice?.id ?? 0 },
                        set: { newID in
                            recorder.selectedMicDevice = recorder.availableMicDevices.first { $0.id == newID }
                        }
                    )) {
                        if recorder.availableMicDevices.isEmpty {
                            Text("未检测到麦克风").tag(AudioDeviceID(0))
                        } else {
                            ForEach(recorder.availableMicDevices) { d in
                                Text(d.displayName).tag(d.id)
                            }
                        }
                    }
                }

                Button {
                    recorder.refreshDevices()
                } label: {
                    Label("刷新设备列表", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("设备")
            } footer: {
                Text(deviceFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 3. 混录参数（仅 mix 模式）
            if recorder.recordingMode == .mix {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("系统音频音量")
                            Spacer()
                            Text("\(Int(recorder.mixSystemGain * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $recorder.mixSystemGain, in: 0...2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("麦克风音量")
                            Spacer()
                            Text("\(Int(recorder.mixMicGain * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $recorder.mixMicGain, in: 0...2)
                    }
                    Toggle("保留原始两路音频", isOn: $recorder.keepOriginalTracks)
                } header: {
                    Text("混录参数")
                } footer: {
                    Text("两路音频独立采集，停止录制后用 ffmpeg amix 合并。录制过程中的实时转写预览仅基于系统音频，最终任务队列会重转合并后的完整音频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 4. 智能停止
            Section {
                Toggle("静音超时自动停止", isOn: $recorder.silenceAutoStopEnabled)
                Stepper(value: Binding(
                    get: { Int(recorder.silenceTimeoutSec / 60) },
                    set: { recorder.silenceTimeoutSec = TimeInterval($0 * 60) }
                ), in: 1...30) {
                    HStack {
                        Text("超时阈值")
                        Spacer()
                        Text("\(Int(recorder.silenceTimeoutSec / 60)) 分钟")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!recorder.silenceAutoStopEnabled)
            } header: {
                Text("智能停止")
            } footer: {
                Text("超过设定时间未检测到声音，自动停止当前录制。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var modeFooterText: String {
        switch recorder.recordingMode {
        case .systemAudio: return "录制电脑播放的声音（需要 BlackHole 等环回设备）。"
        case .microphone:  return "录制麦克风采集的真实声音。"
        case .mix:         return "同时采集系统音频和麦克风，录制结束后自动合并为一个文件。"
        }
    }

    private var deviceFooterText: String {
        switch recorder.recordingMode {
        case .systemAudio:
            return recorder.availableSystemDevices.isEmpty
                ? "未检测到环回设备。需要安装 BlackHole 才能录制系统音。"
                : "选择用于录制系统输出的环回设备。"
        case .microphone:
            return recorder.availableMicDevices.isEmpty
                ? "未检测到麦克风。请检查系统设置 → 隐私与安全性 → 麦克风权限。"
                : "选择用于录制的麦克风设备。"
        case .mix:
            return "混录模式需要同时指定一个环回设备和一个麦克风。"
        }
    }

    // MARK: - 存储

    private var storageTab: some View {
        Form {
            Section("下载目录") {
                directoryRow(
                    path: effectiveDownloadDir,
                    onChoose: { chooseDirectory { newPath in downloadDir = newPath } },
                    onReveal: { revealInFinder(effectiveDownloadDir) }
                )
            }
            Section("录制目录") {
                directoryRow(
                    path: effectiveRecordingDir,
                    onChoose: { chooseDirectory { newPath in recordingDir = newPath } },
                    onReveal: { revealInFinder(effectiveRecordingDir) }
                )
            }
        }
        .formStyle(.grouped)
    }

    private func directoryRow(path: String, onChoose: @escaping () -> Void, onReveal: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(displayPath(path))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("在 Finder 中显示", action: onReveal)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("选择…", action: onChoose)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - 依赖

    private var dependenciesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("运行环境检查").font(.headline)
                Spacer()
                Button(action: { Task { await checkDependencies() } }) {
                    Label("重新检查", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .disabled(isCheckingDeps)
            }

            if isCheckingDeps {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("检查中…").font(.caption).foregroundStyle(.secondary)
                }
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(dependencyResults.enumerated()), id: \.element.id) { idx, dep in
                        depRow(dep)
                        if idx < dependencyResults.count - 1 {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
            .frame(maxHeight: .infinity)

            if !allDepsReady {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("缺少关键依赖，部分功能可能不可用")
                        .font(.caption)
                    Spacer()
                    Button(action: { Task { await installDeps() } }) {
                        Label(isInstalling ? "安装中…" : "一键安装", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isInstalling)
                }
            }
        }
        .padding()
    }

    private func depRow(_ dep: DependencyManager.DependencyCheck) -> some View {
        HStack(spacing: 12) {
            Image(systemName: dep.status.icon)
                .foregroundStyle(colorForStatus(dep.status))
                .font(.system(size: 18))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(dep.name).fontWeight(.medium)
                Text(dep.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(unifiedStatusText(dep))
                .font(.caption.monospacedDigit())
                .foregroundStyle(colorForStatus(dep.status))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 关于

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 4)
            AppIconView(size: 96)

            Text("AudioNote").font(.title.weight(.bold))
            Text(appVersionDisplay).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(spacing: 4) {
                Text("把任何来源的声音变成文字稿").font(.callout)
                Text("• 下载网络视频  • 录制系统/麦克风  • 拖入文件转写")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)

            Divider().frame(width: 220)

            HStack(spacing: 16) {
                Button {
                    NSWorkspace.shared.open(Logger.logDir)
                } label: {
                    Label("打开日志目录", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                Button {
                    if let url = URL(string: "https://github.com/fanbaocheng/audio-note") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("项目主页", systemImage: "link")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)

            Spacer()

            Text("© 2026 ryanfan · MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
        }
        .padding()
    }

    // MARK: - 版本信息

    /// 从 Info.plist 读出 marketing version + build version，形如 "v1.0.1 (1.0.1_2026/06/30_18:37:57)"
    private var appVersionDisplay: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        if build.isEmpty || build == short {
            return "v\(short)"
        }
        return "v\(short)  ·  \(build)"
    }

    // MARK: - 操作

    private var effectiveDownloadDir: String {
        downloadDir.isEmpty ? "\(NSHomeDirectory())/Documents/AudioNote/Downloads" : downloadDir
    }

    private var effectiveRecordingDir: String {
        recordingDir.isEmpty ? "\(NSHomeDirectory())/Documents/AudioNote/Recordings" : recordingDir
    }

    private func displayPath(_ p: String) -> String {
        let home = NSHomeDirectory()
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func chooseDirectory(_ onPick: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onPick(url.path)
        }
    }

    private func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func checkDependencies() async {
        isCheckingDeps = true
        await DependencyManager.shared.runAllChecks()
        dependencyResults = DependencyManager.shared.checkResults
        allDepsReady = DependencyManager.shared.allReady
        isCheckingDeps = false
    }

    private func installDeps() async {
        isInstalling = true
        do {
            try await DependencyManager.shared.installPythonDependencies()
            try await DependencyManager.shared.downloadModel { _ in }
        } catch {
            Logger.app.error("安装依赖失败", error: error)
        }
        isInstalling = false
        await checkDependencies()
    }

    private func colorForStatus(_ s: DependencyManager.DependencyCheck.CheckStatus) -> Color {
        switch s {
        case .pending, .checking: return .secondary
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    /// 统一状态文案：版本号优先；无版本号则统一显示「已就绪 / 已安装」；异常则展示原因
    private func unifiedStatusText(_ dep: DependencyManager.DependencyCheck) -> String {
        switch dep.status {
        case .pending: return "待检查"
        case .checking: return "检查中…"
        case .ok:
            let detail = dep.detail.trimmingCharacters(in: .whitespaces)
            if detail.isEmpty { return "就绪" }
            // detail 已经像 "v3.14.5" 或 "已安装"，直接用
            return detail
        case .warning(let m): return m
        case .error(let m): return m
        }
    }
}

// MARK: - AppIconView：读取系统 app icon

private struct AppIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: nil) ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}
