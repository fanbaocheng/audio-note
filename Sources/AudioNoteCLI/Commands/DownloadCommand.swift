import Foundation
import ArgumentParser
import AudioNoteCore

/// download 子命令：URL → 本地音频文件
struct DownloadCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "download",
        abstract: "下载远程音视频（http/https/B站/YouTube/...）到本地"
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "远程 URL")
    var url: String

    @Option(name: .long, help: "下载模式：audio（默认）/ video")
    var mode: String = "audio"

    @Option(name: .long, help: "输出目录（默认沿用 settings 中的 downloads.dir）")
    var output: String?

    @Option(name: .long, help: "Cookie 来源（none/chrome/safari/firefox/edge/brave）")
    var cookie: String?

    @Flag(name: .long, help: "占用 GUI 时强制接管")
    var forceTakeover: Bool = false

    @MainActor
    mutating func run() async throws {
        common.applyOutputMode()
        let lock = common.acquireLockOrExit(forceTakeover: forceTakeover)
        _ = lock

        // 应用 settings（CLI 也需要先吸入持久化配置，否则 DownloadEngine 用默认目录）
        applyPersistedDownloadSettings()

        // 覆盖参数
        if let output = output {
            let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            DownloadEngine.shared.config.outputDir = url
        }
        if let cookie = cookie, let src = CookieSource(rawValue: cookie) {
            DownloadEngine.shared.config.cookieSource = src
        }

        let dm: DownloadMode = (mode == "video") ? .video : .audio
        let task = UniTask(inputType: .urlDownload, sourceURL: url, downloadMode: dm)

        SignalHandler.install {
            CLIOut.event("cancelled")
            task.process?.terminate()
        }

        CLIOut.event("start", payload: ["url": url, "mode": dm.rawValue])
        do {
            let out = try await DownloadEngine.shared.execute(task: task)
            let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
            let size = (attrs?[.size] as? Int) ?? 0
            CLIOut.result([
                "file": out.path,
                "size_bytes": size,
                "title": task.title,
                "uploader": task.uploader ?? ""
            ], humanText: "✓ 下载完成：\(out.path)（\(size / 1024)KB）")
            CLIOut.done(["file": out.path])
        } catch {
            CLIOut.error("下载失败：\(error.localizedDescription)", code: "DOWNLOAD_FAILED")
            throw ExitCodeWrapper(74)
        }
    }
}

/// 把 GUI 启动时做的持久化设置注入到当前进程（CLI 同样需要）
func applyPersistedDownloadSettings() {
    let ud = AppDefaults.shared
    let dlSaved = ud.string(forKey: "AudioNote.downloadsDirectoryPath") ?? ""
    let dlPath = dlSaved.isEmpty
        ? "\(NSHomeDirectory())/Documents/AudioNote/Downloads"
        : (dlSaved as NSString).expandingTildeInPath
    let dlURL = URL(fileURLWithPath: dlPath)
    try? FileManager.default.createDirectory(at: dlURL, withIntermediateDirectories: true)
    Task { @MainActor in DownloadEngine.shared.config.outputDir = dlURL }

    let cookieRaw = ud.string(forKey: "cookieSource") ?? CookieSource.none.rawValue
    if let src = CookieSource(rawValue: cookieRaw) {
        Task { @MainActor in DownloadEngine.shared.config.cookieSource = src }
    }
}
