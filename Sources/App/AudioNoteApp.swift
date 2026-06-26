import SwiftUI

/// App 入口 + 全局状态初始化
@main
struct AudioNoteApp: App {
    @StateObject private var scheduler = TaskScheduler.shared
    @StateObject private var recorder  = AudioCaptureEngine.shared
    @StateObject private var asr       = ASRService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(scheduler)
                .environmentObject(recorder)
                .environmentObject(asr)
                .onAppear {
                    Logger.app.info("AudioNote 启动")
                    Logger.app.info(BinaryResolver.diagnostic())
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
        let ud = UserDefaults.standard

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
}
