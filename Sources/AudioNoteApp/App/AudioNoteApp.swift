import SwiftUI
import AudioNoteCore
import AppKit

/// App 入口 + 全局状态初始化
@main
struct AudioNoteApp: App {
    @StateObject private var scheduler = TaskScheduler.shared
    @StateObject private var recorder  = AudioCaptureEngine.shared
    @StateObject private var asr       = ASRService.shared

    // 启动时拿到的互斥锁；只要 App 进程存活就持有
    @State private var lock: SingleInstanceLock?

    // NSApplicationDelegate 桥接——最后一个窗口关闭时自动退出 App，
    // 避免「关闭窗口 → 进程还在跑、锁未释放 → 点 dock 图标弹冲突框」的问题
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(scheduler)
                .environmentObject(recorder)
                .environmentObject(asr)
                .onAppear {
                    Logger.app.info("AudioNote 启动")
                    Logger.app.info(BinaryResolver.diagnostic())
                    acquireSingleInstanceLock()
                    installSigtermHandler()
                    applyPersistedSettings()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(recorder)
                .environmentObject(scheduler)
                .frame(width: 520, height: 440)
        }
    }

    /// 应用启动时把持久化的设置同步到运行时引擎（重启后无需打开 Settings 即生效）
    @MainActor
    private func applyPersistedSettings() {
        let ud = AppDefaults.shared

        // 一次性迁移：老 key -> 新 key（之前 SettingsView 用错了 key，导致设置不生效）
        if let legacy = ud.string(forKey: "downloadDir"), !legacy.isEmpty {
            if (ud.string(forKey: "AudioNote.downloadsDirectoryPath") ?? "").isEmpty {
                ud.set(legacy, forKey: "AudioNote.downloadsDirectoryPath")
                Logger.app.info("迁移 downloadDir -> AudioNote.downloadsDirectoryPath", metadata: ["path": legacy])
            }
            ud.removeObject(forKey: "downloadDir")
        }
        if let legacy = ud.string(forKey: "recordingDir"), !legacy.isEmpty {
            if (ud.string(forKey: AudioCaptureEngine.recordingsDirectoryPathKey) ?? "").isEmpty {
                ud.set(legacy, forKey: AudioCaptureEngine.recordingsDirectoryPathKey)
                Logger.app.info("迁移 recordingDir -> AudioNote.recordingsDirectoryPath", metadata: ["path": legacy])
            }
            ud.removeObject(forKey: "recordingDir")
        }

        // 下载目录
        let dlSaved = ud.string(forKey: "AudioNote.downloadsDirectoryPath") ?? ""
        let dlPath = dlSaved.isEmpty
            ? "\(NSHomeDirectory())/Documents/AudioNote/Downloads"
            : (dlSaved as NSString).expandingTildeInPath
        let dlURL = URL(fileURLWithPath: dlPath)
        try? FileManager.default.createDirectory(at: dlURL, withIntermediateDirectories: true)
        DownloadEngine.shared.config.outputDir = dlURL

        // Cookie 源
        let cookieRaw = ud.string(forKey: "cookieSource") ?? CookieSource.none.rawValue
        if let src = CookieSource(rawValue: cookieRaw) {
            DownloadEngine.shared.config.cookieSource = src
        }

        Logger.app.info("已应用持久化设置", metadata: [
            "downloadDir": dlURL.path,
            "recordingDir": AudioCaptureEngine.resolveRecordingsDirectory().path,
            "cookie": DownloadEngine.shared.config.cookieSource.rawValue
        ])
    }

    /// 获取单实例锁——与 CLI 互斥。
    /// 已有持有者时弹窗提示并退出（让用户先 `pkill audio-note` 或关闭已开的 GUI）。
    @MainActor
    private func acquireSingleInstanceLock() {
        switch SingleInstanceLock.acquire(mode: .gui) {
        case .acquired(let l):
            lock = l
            Logger.app.info("SingleInstanceLock acquired (gui)")
        case .conflict(let holder):
            Logger.app.error("SingleInstanceLock conflict: \(holder.description)")
            let alert = NSAlert()
            alert.messageText = "AudioNote 已在运行"
            alert.informativeText = "另一个实例正在运行：\n\(holder.description)\n\n请先关闭它再启动 GUI。"
            alert.alertStyle = .critical
            alert.addButton(withTitle: "退出")
            alert.runModal()
            NSApp.terminate(nil)
        case .error(let err):
            Logger.app.warn("SingleInstanceLock acquire failed (continuing anyway): \(err)")
        }
    }

    /// 注册 SIGTERM：CLI 用 --force-takeover 时会 SIGTERM 给 GUI，GUI 收到后优雅退出
    @MainActor
    private func installSigtermHandler() {
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Logger.app.info("收到 SIGTERM，优雅退出")
            NSApp.terminate(nil)
        }
        source.resume()
        // 默认 SIGTERM 行为是立即杀进程，必须显式忽略才能让 DispatchSource 拿到
        signal(SIGTERM, SIG_IGN)
        // 持有 source 避免被释放
        Self.sigtermSource = source
    }

    private static var sigtermSource: DispatchSourceSignal?
}

/// NSApplicationDelegate 桥接
///
/// 当前职责：最后一个窗口关闭时自动退出 App（避免「关闭窗口 ≠ 退出进程」导致的 dock 冲突弹窗）
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
