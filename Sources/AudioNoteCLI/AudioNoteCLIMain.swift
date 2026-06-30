import Foundation
import ArgumentParser
import AudioNoteCore

/// audio-note CLI 入口
///
/// 顶层命令组：
///   - device     声卡 / 麦克风设备
///   - record     录音
///   - transcribe 转写（本地文件或 URL）
///   - download   URL 下载
///   - library    录音库管理
///   - settings   读写配置
///
/// 设计原则：
/// - GUI 与 CLI 进程**完全互斥**：靠 SingleInstanceLock 协调。
/// - 业务代码 100% 复用 AudioNoteCore。
/// - 输出模式：默认人类可读；`--json` 走 JSON Lines (stdout 100% JSON)。
struct AudioNote: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "audio-note",
        abstract: "AudioNote CLI — 录音、转写、下载、库管理（与 GUI App 共享数据）",
        version: "0.3.0",
        subcommands: [
            DeviceCommand.self,
            RecordCommand.self,
            TranscribeCommand.self,
            DownloadCommand.self,
            LibraryCommand.self,
            SettingsCommand.self
        ]
    )
}

// 自定义入口：捕获 ExitCodeWrapper 并精确返回 BSD sysexits 退出码
@main
struct AudioNoteEntry {
    static func main() async {
        do {
            var cmd = try AudioNote.parseAsRoot()
            if var asyncCmd = cmd as? AsyncParsableCommand {
                try await asyncCmd.run()
            } else {
                try cmd.run()
            }
            exit(0)
        } catch let exitCode as ExitCodeWrapper {
            exit(exitCode.code)
        } catch {
            // 让 ArgumentParser 处理标准错误（如参数解析失败 → exit 64）
            AudioNote.exit(withError: error)
        }
    }
}
