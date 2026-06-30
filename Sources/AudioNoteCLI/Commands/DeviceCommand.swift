import Foundation
import ArgumentParser
import AudioNoteCore

/// device 子命令：列出 / 刷新 / 设置默认设备
struct DeviceCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "device",
        abstract: "音频设备管理（系统音频 / 麦克风）",
        subcommands: [
            ListSubcommand.self,
            RefreshSubcommand.self,
            DefaultSubcommand.self
        ],
        defaultSubcommand: ListSubcommand.self
    )

    // MARK: list

    struct ListSubcommand: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "list",
            abstract: "列出所有音频输入设备"
        )

        @OptionGroup var common: CommonOptions

        @Option(name: [.customLong("kind"), .customLong("type")], help: "只显示指定类型：system / mic / all")
        var kind: DeviceTypeFilter = .all

        @MainActor
        mutating func run() async throws {
            common.applyOutputMode()
            let engine = AudioCaptureEngine.shared
            engine.refreshDevices()

            var rows: [[String: Any]] = []
            if kind == .all || kind == .system {
                for d in engine.availableSystemDevices {
                    rows.append([
                        "kind": "system",
                        "id": d.id,
                        "uid": d.uid,
                        "name": d.name,
                        "selected": engine.selectedSystemDevice?.id == d.id
                    ])
                }
            }
            if kind == .all || kind == .mic {
                for d in engine.availableMicDevices {
                    rows.append([
                        "kind": "mic",
                        "id": d.id,
                        "uid": d.uid,
                        "name": d.name,
                        "selected": engine.selectedMicDevice?.id == d.id
                    ])
                }
            }

            CLIOut.table(
                rows: rows,
                columns: [
                    (key: "kind", header: "TYPE", width: 6),
                    (key: "id", header: "ID", width: 5),
                    (key: "name", header: "NAME", width: nil),
                    (key: "selected", header: "SELECTED", width: 8)
                ],
                emptyText: "(没有可用音频设备)"
            )
        }

        enum DeviceTypeFilter: String, ExpressibleByArgument {
            case all, system, mic
        }
    }

    // MARK: refresh

    struct RefreshSubcommand: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "refresh",
            abstract: "重新扫描音频设备"
        )
        @OptionGroup var common: CommonOptions

        @MainActor
        mutating func run() async throws {
            common.applyOutputMode()
            let engine = AudioCaptureEngine.shared
            engine.refreshDevices()
            CLIOut.result([
                "system_devices": engine.availableSystemDevices.count,
                "mic_devices": engine.availableMicDevices.count
            ], humanText: "已刷新：\(engine.availableSystemDevices.count) 个系统音频设备，\(engine.availableMicDevices.count) 个麦克风")
        }
    }

    // MARK: default

    struct DefaultSubcommand: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "default",
            abstract: "查看 / 设置默认设备",
            subcommands: [GetSub.self, SetSub.self],
            defaultSubcommand: GetSub.self
        )

        struct GetSub: AsyncParsableCommand {
            static var configuration = CommandConfiguration(commandName: "get", abstract: "查看当前选中的默认设备")
            @OptionGroup var common: CommonOptions

            @MainActor
            mutating func run() async throws {
                common.applyOutputMode()
                let e = AudioCaptureEngine.shared
                e.refreshDevices()
                var payload: [String: Any] = [:]
                if let s = e.selectedSystemDevice {
                    payload["system"] = ["id": s.id, "name": s.name, "uid": s.uid]
                }
                if let m = e.selectedMicDevice {
                    payload["mic"] = ["id": m.id, "name": m.name, "uid": m.uid]
                }
                let humanText = """
                系统音频：\(e.selectedSystemDevice?.name ?? "(未选择)")
                麦克风：  \(e.selectedMicDevice?.name ?? "(未选择)")
                """
                CLIOut.result(payload, humanText: humanText)
            }
        }

        struct SetSub: AsyncParsableCommand {
            static var configuration = CommandConfiguration(commandName: "set", abstract: "设置默认设备")
            @OptionGroup var common: CommonOptions

            @Option(name: .long, help: "system / mic")
            var kind: String

            @Option(name: .long, help: "设备 ID（数字）或 UID（字符串）")
            var device: String

            @MainActor
            mutating func run() async throws {
                common.applyOutputMode()
                let e = AudioCaptureEngine.shared
                e.refreshDevices()
                let pool: [AudioCaptureEngine.AudioInputDevice]
                switch kind {
                case "system": pool = e.availableSystemDevices
                case "mic":    pool = e.availableMicDevices
                default:
                    CLIOut.error("--kind 必须是 system 或 mic", code: "USAGE")
                    throw ExitCodeWrapper(64)
                }
                // 数字 → id；否则 → uid 匹配
                let target: AudioCaptureEngine.AudioInputDevice?
                if let did = UInt32(device) {
                    target = pool.first(where: { $0.id == did })
                } else {
                    target = pool.first(where: { $0.uid == device || $0.name == device })
                }
                guard let chosen = target else {
                    CLIOut.error("找不到设备：\(device)", code: "NOT_FOUND")
                    throw ExitCodeWrapper(66)
                }
                if kind == "system" {
                    e.selectedSystemDevice = chosen
                } else {
                    e.selectedMicDevice = chosen
                }
                CLIOut.result(["kind": kind, "id": chosen.id, "name": chosen.name, "uid": chosen.uid],
                              humanText: "已设置默认 \(kind) 设备：\(chosen.name)")
            }
        }
    }
}

/// 用于把 BSD exit code 抛回 swift-argument-parser
///
/// 实现 ExitCode 协议（来自 ArgumentParser）以便 exit code 能正确传递给 shell，
/// 同时 description 为空字符串，避免 ArgumentParser 输出多余的 "Error: ..." 行。
struct ExitCodeWrapper: Error, CustomStringConvertible {
    let code: Int32
    init(_ code: Int32) { self.code = code }
    var description: String { "" }
}

extension ExitCodeWrapper: CustomNSError {
    var errorCode: Int { Int(code) }
}
