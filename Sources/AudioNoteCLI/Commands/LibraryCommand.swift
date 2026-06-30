import Foundation
import ArgumentParser
import AudioNoteCore

/// library 子命令：管理录音库 / 历史任务
struct LibraryCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "library",
        abstract: "查看 / 管理录音库与历史任务",
        subcommands: [ListSub.self, ShowSub.self, ExportSub.self, DeleteSub.self],
        defaultSubcommand: ListSub.self
    )

    // MARK: list

    struct ListSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "list", abstract: "列出所有录音条目与任务")
        @OptionGroup var common: CommonOptions

        @Option(name: .long, help: "筛选状态：all/completed/failed/pending/running")
        var status: String = "all"

        @MainActor
        mutating func run() async throws {
            common.applyOutputMode()
            let tasks = TaskScheduler.shared.allTasks
            let filtered = filterByStatus(tasks, status)

            // 同时把"录音目录里没入过任务库"的孤立 wav 文件也列出来
            let recordingsDir = AudioCaptureEngine.resolveRecordingsDirectory()
            let allFiles = (try? FileManager.default.contentsOfDirectory(at: recordingsDir, includingPropertiesForKeys: [.fileSizeKey, .creationDateKey]))
                ?? []
            let taskFileSet = Set(tasks.compactMap { $0.outputFileURL?.path })
            let orphanFiles = allFiles.filter {
                let p = $0.path
                return ($0.pathExtension.lowercased() == "wav") && !taskFileSet.contains(p)
            }

            var rows: [[String: Any]] = []
            for t in filtered {
                rows.append([
                    "id": String(t.id.uuidString.prefix(8)),
                    "type": t.inputType.rawValue,
                    "title": t.displayTitle,
                    "status": t.status.displayText,
                    "audio": t.outputFileURL?.path ?? "",
                    "transcript": t.transcriptURL?.path ?? "",
                    "chars": t.transcriptCharCount,
                    "created": ISO8601DateFormatter().string(from: t.createdAt)
                ])
            }
            // 孤立文件作为 type=orphan 显示，便于 transcribe
            for f in orphanFiles {
                let attrs = try? f.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                rows.append([
                    "id": "(file)",
                    "type": "orphan",
                    "title": f.lastPathComponent,
                    "status": "(无任务)",
                    "audio": f.path,
                    "transcript": "",
                    "chars": 0,
                    "created": (attrs?.creationDate).map { ISO8601DateFormatter().string(from: $0) } ?? ""
                ])
            }

            CLIOut.table(
                rows: rows,
                columns: [
                    (key: "id", header: "ID", width: 10),
                    (key: "type", header: "TYPE", width: 8),
                    (key: "status", header: "STATUS", width: 14),
                    (key: "title", header: "TITLE", width: nil)
                ],
                emptyText: "(录音库为空)"
            )
        }

        private func filterByStatus(_ tasks: [UniTask], _ filter: String) -> [UniTask] {
            switch filter {
            case "completed":
                return tasks.filter { if case .completed = $0.status { return true }; return false }
            case "failed":
                return tasks.filter { if case .failed = $0.status { return true }; return false }
            case "pending":
                return tasks.filter { if case .pending = $0.status { return true }; return false }
            case "running":
                return tasks.filter { $0.status.isRunning }
            default:
                return tasks
            }
        }
    }

    // MARK: show

    struct ShowSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "show", abstract: "查看单条任务详情")
        @OptionGroup var common: CommonOptions
        @Argument(help: "任务 ID 前缀（至少 4 字符）")
        var id: String

        @MainActor
        mutating func run() async throws {
            common.applyOutputMode()
            guard let task = TaskScheduler.shared.allTasks.first(where: { $0.id.uuidString.hasPrefix(id) }) else {
                CLIOut.error("找不到 ID 以 \(id) 开头的任务", code: "NOT_FOUND")
                throw ExitCodeWrapper(66)
            }
            var payload: [String: Any] = [
                "id": task.id.uuidString,
                "title": task.title,
                "type": task.inputType.rawValue,
                "status": task.status.displayText,
                "audio": task.outputFileURL?.path ?? "",
                "transcript_txt": task.transcriptURL?.path ?? "",
                "transcript_srt": task.transcriptSRTURL?.path ?? "",
                "chars": task.transcriptCharCount,
                "source_url": task.sourceURL ?? "",
                "source_file": task.sourceFilePath ?? "",
                "created": ISO8601DateFormatter().string(from: task.createdAt)
            ]
            if let started = task.startedAt { payload["started"] = ISO8601DateFormatter().string(from: started) }
            if let finished = task.finishedAt { payload["finished"] = ISO8601DateFormatter().string(from: finished) }
            CLIOut.result(payload, humanText: """
            ID:        \(task.id.uuidString)
            Title:     \(task.title)
            Type:      \(task.inputType.rawValue)
            Status:    \(task.status.displayText)
            Audio:     \(task.outputFileURL?.path ?? "-")
            Transcript:\(task.transcriptURL?.path ?? "-")
            Chars:     \(task.transcriptCharCount)
            """)
        }
    }

    // MARK: export

    struct ExportSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "export", abstract: "把任务音频或转写复制到指定路径")
        @OptionGroup var common: CommonOptions
        @Argument(help: "任务 ID 前缀")
        var id: String
        @Option(name: .long, help: "要导出的内容：audio / transcript")
        var kind: String = "transcript"
        @Option(name: .long, help: "目标路径（默认 stdout）")
        var to: String?

        @MainActor
        mutating func run() async throws {
            common.applyOutputMode()
            guard let task = TaskScheduler.shared.allTasks.first(where: { $0.id.uuidString.hasPrefix(id) }) else {
                CLIOut.error("找不到任务 \(id)", code: "NOT_FOUND")
                throw ExitCodeWrapper(66)
            }
            let srcURL: URL?
            switch kind {
            case "audio": srcURL = task.outputFileURL
            case "transcript": srcURL = task.transcriptURL
            default:
                CLIOut.error("--kind 必须是 audio 或 transcript", code: "USAGE")
                throw ExitCodeWrapper(64)
            }
            guard let src = srcURL else {
                CLIOut.error("任务还没有 \(kind) 产物", code: "NO_OUTPUT")
                throw ExitCodeWrapper(66)
            }
            if let to = to {
                let raw = (to as NSString).expandingTildeInPath
                var isDir: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: raw, isDirectory: &isDir)
                // 如果 to 是已存在目录，或以 / 结尾 → 把 src 文件名追加进去
                let dest: URL
                if exists && isDir.boolValue {
                    dest = URL(fileURLWithPath: raw).appendingPathComponent(src.lastPathComponent)
                } else if raw.hasSuffix("/") {
                    try FileManager.default.createDirectory(atPath: raw, withIntermediateDirectories: true)
                    dest = URL(fileURLWithPath: raw).appendingPathComponent(src.lastPathComponent)
                } else {
                    dest = URL(fileURLWithPath: raw)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: src, to: dest)
                CLIOut.result(["from": src.path, "to": dest.path], humanText: "✓ 已导出到：\(dest.path)")
            } else {
                if kind == "transcript" {
                    let text = (try? String(contentsOf: src, encoding: .utf8)) ?? ""
                    if common.json {
                        CLIOut.result(["from": src.path, "content": text])
                    } else {
                        print(text)
                    }
                } else {
                    CLIOut.error("--kind audio 不支持输出到 stdout，请用 --to <path>", code: "USAGE")
                    throw ExitCodeWrapper(64)
                }
            }
        }
    }

    // MARK: delete

    struct DeleteSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "delete", abstract: "删除任务（可选连带文件）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "任务 ID 前缀")
        var id: String
        @Flag(name: .long, help: "同时删除音频与转写文件")
        var withFiles: Bool = false

        @MainActor
        mutating func run() async throws {
            common.applyOutputMode()
            guard let task = TaskScheduler.shared.allTasks.first(where: { $0.id.uuidString.hasPrefix(id) }) else {
                CLIOut.error("找不到任务 \(id)", code: "NOT_FOUND")
                throw ExitCodeWrapper(66)
            }
            if withFiles {
                if let u = task.outputFileURL { try? FileManager.default.removeItem(at: u) }
                if let u = task.transcriptURL { try? FileManager.default.removeItem(at: u) }
                if let u = task.transcriptSRTURL { try? FileManager.default.removeItem(at: u) }
            }
            TaskScheduler.shared.remove(task)
            TaskScheduler.shared.persist()
            CLIOut.result(["id": task.id.uuidString, "deleted_files": withFiles],
                          humanText: "✓ 已删除任务 \(task.id.uuidString.prefix(8))" + (withFiles ? "（含文件）" : ""))
        }
    }
}
