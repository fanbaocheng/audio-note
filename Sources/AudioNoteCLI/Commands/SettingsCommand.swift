import Foundation
import ArgumentParser
import AudioNoteCore

/// settings 子命令：读写 AppDefaults
///
/// 支持的 keys（点号路径 → 真实 UserDefaults key）：
///   recording.mode                       → AudioNote.recordingMode  (system/mic/mix)
///   recording.dir                        → AudioNote.recordingsDirectoryPath
///   recording.silence_timeout_min        → AudioNote.silenceTimeoutMin (新增)
///   recording.mix.system_gain            → AudioNote.mixSystemGain (0..2)
///   recording.mix.mic_gain               → AudioNote.mixMicGain
///   recording.mix.keep_originals         → AudioNote.keepOriginalTracks
///   downloads.dir                        → AudioNote.downloadsDirectoryPath
///   downloads.cookie_source              → cookieSource
///   downloads.max_concurrent             → maxConcurrentDownloads
struct SettingsCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "settings",
        abstract: "读写应用配置（与 GUI 共享）",
        subcommands: [GetSub.self, SetSub.self, ListSub.self, ResetSub.self],
        defaultSubcommand: ListSub.self
    )

    static let keyMap: [String: SettingKey] = [
        "recording.mode": .init(udKey: "AudioNote.recordingMode", kind: .string, desc: "录制模式 system/mic/mix"),
        "recording.dir": .init(udKey: "AudioNote.recordingsDirectoryPath", kind: .path, desc: "录音保存目录"),
        "recording.silence_timeout_min": .init(udKey: "AudioNote.silenceTimeoutMin", kind: .double, desc: "静音自动停止阈值（分钟）"),
        "recording.mix.system_gain": .init(udKey: "AudioNote.mixSystemGain", kind: .double, desc: "混录系统音频增益 0..2"),
        "recording.mix.mic_gain": .init(udKey: "AudioNote.mixMicGain", kind: .double, desc: "混录麦克风增益 0..2"),
        "recording.mix.keep_originals": .init(udKey: "AudioNote.keepOriginalTracks", kind: .bool, desc: "混录后是否保留 sys/mic 原始 wav"),
        "downloads.dir": .init(udKey: "AudioNote.downloadsDirectoryPath", kind: .path, desc: "下载目录"),
        "downloads.cookie_source": .init(udKey: "cookieSource", kind: .string, desc: "yt-dlp cookie 来源（none/chrome/safari/firefox/edge/brave）"),
        "downloads.max_concurrent": .init(udKey: "maxConcurrentDownloads", kind: .int, desc: "下载并发数")
    ]

    struct SettingKey {
        let udKey: String
        let kind: Kind
        let desc: String
        enum Kind { case string, int, double, bool, path }
    }

    // MARK: list

    struct ListSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "list", abstract: "列出所有可配置项及当前值")
        @OptionGroup var common: CommonOptions

        mutating func run() async throws {
            common.applyOutputMode()
            let ud = AppDefaults.shared
            var rows: [[String: Any]] = []
            for (path, meta) in SettingsCommand.keyMap.sorted(by: { $0.key < $1.key }) {
                let value = SettingsCommand.readValue(ud: ud, meta: meta)
                rows.append([
                    "key": path,
                    "value": String(describing: value ?? ""),
                    "description": meta.desc
                ])
            }
            CLIOut.table(
                rows: rows,
                columns: [
                    (key: "key", header: "KEY", width: 36),
                    (key: "value", header: "VALUE", width: 30),
                    (key: "description", header: "DESCRIPTION", width: nil)
                ],
                emptyText: "(无设置项)"
            )
        }
    }

    // MARK: get

    struct GetSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "get", abstract: "读取单个配置项")
        @OptionGroup var common: CommonOptions
        @Argument(help: "配置 key（点号路径）")
        var key: String

        mutating func run() async throws {
            common.applyOutputMode()
            guard let meta = SettingsCommand.keyMap[key] else {
                CLIOut.error("未知配置项：\(key)。运行 `audio-note settings list` 查看所有项。", code: "UNKNOWN_KEY")
                throw ExitCodeWrapper(64)
            }
            let v = SettingsCommand.readValue(ud: AppDefaults.shared, meta: meta)
            CLIOut.result(["key": key, "value": v as Any], humanText: "\(key) = \(String(describing: v ?? ""))")
        }
    }

    // MARK: set

    struct SetSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "set", abstract: "写入单个配置项")
        @OptionGroup var common: CommonOptions
        @Argument(help: "配置 key（点号路径）")
        var key: String
        @Argument(help: "新的值")
        var value: String

        mutating func run() async throws {
            common.applyOutputMode()
            guard let meta = SettingsCommand.keyMap[key] else {
                CLIOut.error("未知配置项：\(key)", code: "UNKNOWN_KEY")
                throw ExitCodeWrapper(64)
            }
            let ud = AppDefaults.shared
            switch meta.kind {
            case .string:
                ud.set(value, forKey: meta.udKey)
            case .path:
                let p = (value as NSString).expandingTildeInPath
                ud.set(p, forKey: meta.udKey)
            case .int:
                guard let n = Int(value) else {
                    CLIOut.error("\(key) 需要整数", code: "INVALID_VALUE"); throw ExitCodeWrapper(64)
                }
                ud.set(n, forKey: meta.udKey)
            case .double:
                guard let n = Double(value) else {
                    CLIOut.error("\(key) 需要数字", code: "INVALID_VALUE"); throw ExitCodeWrapper(64)
                }
                ud.set(n, forKey: meta.udKey)
            case .bool:
                let on = ["true", "1", "yes", "on"].contains(value.lowercased())
                ud.set(on, forKey: meta.udKey)
            }
            ud.synchronize()
            let v = SettingsCommand.readValue(ud: ud, meta: meta)
            CLIOut.result(["key": key, "value": v as Any], humanText: "✓ 已设置 \(key) = \(String(describing: v ?? ""))")
        }
    }

    // MARK: reset

    struct ResetSub: AsyncParsableCommand {
        static var configuration = CommandConfiguration(commandName: "reset", abstract: "重置某个配置项（或全部）")
        @OptionGroup var common: CommonOptions
        @Argument(help: "配置 key（点号路径），省略或加 --all = 重置所有 audio-note 已知项")
        var key: String?
        @Flag(name: .long, help: "重置所有 audio-note 已知项（等同省略 key）")
        var all: Bool = false

        mutating func run() async throws {
            common.applyOutputMode()
            let ud = AppDefaults.shared
            if let k = key, !all {
                guard let meta = SettingsCommand.keyMap[k] else {
                    CLIOut.error("未知配置项：\(k)", code: "UNKNOWN_KEY"); throw ExitCodeWrapper(64)
                }
                ud.removeObject(forKey: meta.udKey)
                CLIOut.result(["key": k, "reset": true], humanText: "✓ 已重置 \(k)")
            } else {
                for (_, meta) in SettingsCommand.keyMap {
                    ud.removeObject(forKey: meta.udKey)
                }
                CLIOut.result(["reset_all": true, "count": SettingsCommand.keyMap.count],
                              humanText: "✓ 已重置 \(SettingsCommand.keyMap.count) 项设置")
            }
        }
    }

    // MARK: helpers

    static func readValue(ud: UserDefaults, meta: SettingKey) -> Any? {
        switch meta.kind {
        case .string, .path: return ud.string(forKey: meta.udKey)
        case .int: return ud.object(forKey: meta.udKey).map { _ in ud.integer(forKey: meta.udKey) }
        case .double: return ud.object(forKey: meta.udKey).map { _ in ud.double(forKey: meta.udKey) }
        case .bool: return ud.object(forKey: meta.udKey).map { _ in ud.bool(forKey: meta.udKey) }
        }
    }
}
