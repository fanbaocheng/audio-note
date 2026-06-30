import Foundation
import ArgumentParser
import AudioNoteCore

/// transcribe 子命令：本地文件 / URL 自动识别 → 转写
struct TranscribeCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "转写音频/视频（本地路径或远程 URL 都行）"
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "本地文件路径或远程 URL")
    var input: String

    @Option(name: .long, help: "输出目录（默认与输入文件同目录）")
    var output: String?

    @Option(name: .long, help: "URL 模式下的下载模式：audio（默认）/ video")
    var downloadMode: String = "audio"

    @Flag(name: .long, help: "占用 GUI 时强制接管")
    var forceTakeover: Bool = false

    @MainActor
    mutating func run() async throws {
        common.applyOutputMode()
        let lock = common.acquireLockOrExit(forceTakeover: forceTakeover)
        _ = lock

        applyPersistedDownloadSettings()

        let isURL = input.hasPrefix("http://") || input.hasPrefix("https://")
        let task: UniTask
        let outDirURL: URL?
        if let output = output {
            let u = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            outDirURL = u
        } else {
            outDirURL = nil
        }

        if isURL {
            // URL → 复用 UnifiedPipeline.processDownload
            let dm: DownloadMode = (downloadMode == "video") ? .video : .audio
            task = UniTask(inputType: .urlDownload, sourceURL: input, downloadMode: dm)
            CLIOut.event("start", payload: ["mode": "url", "url": input])
            await UnifiedPipeline.shared.processDownload(task: task, outputDir: outDirURL)
        } else {
            // 本地文件 → 检查存在性
            let path = (input as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else {
                CLIOut.error("文件不存在：\(path)", code: "NO_INPUT")
                throw ExitCodeWrapper(66)
            }
            let url = URL(fileURLWithPath: path)
            task = UniTask(inputType: .fileImport, sourceFilePath: path)
            CLIOut.event("start", payload: ["mode": "file", "file": path])
            await UnifiedPipeline.shared.processFileImport(task: task, fileURL: url, outputDir: outDirURL)
        }

        switch task.status {
        case .completed(let mediaURL):
            CLIOut.result([
                "audio_file": mediaURL.path,
                "transcript_txt": task.transcriptURL?.path ?? "",
                "chars": task.transcriptCharCount,
                "title": task.title
            ], humanText: "✓ 转写完成：\(task.transcriptURL?.path ?? mediaURL.path)（\(task.transcriptCharCount) 字）")
            CLIOut.done(["transcript": task.transcriptURL?.path ?? ""])
        case .failed(let reason):
            CLIOut.error("转写失败：\(reason)", code: "TRANSCRIBE_FAILED")
            throw ExitCodeWrapper(70)
        case .cancelled:
            CLIOut.error("已取消", code: "CANCELLED")
            throw ExitCodeWrapper(75)
        default:
            CLIOut.error("转写未达完成状态：\(task.status.displayText)", code: "UNEXPECTED_STATE")
            throw ExitCodeWrapper(70)
        }
    }
}
