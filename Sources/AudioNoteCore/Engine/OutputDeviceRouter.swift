import Foundation
import CoreAudio
#if canImport(AppKit)
import AppKit
#endif

/// 系统音频输出路由控制器
///
/// 用于在录制时自动将系统默认输出切到「多输出设备 (Multi-Output Device)」，
/// 让 BlackHole（被 App 采集）与耳机/扬声器（被用户监听）同时出声。
/// 停止录制时自动还原为原设备。
///
/// macOS 概念区分：
/// - **Aggregate Device** (`kAudioAggregateDeviceClassID`, `aggregate`): 把多设备**输入**合并成一个 → 录音棚专用
/// - **Multi-Output Device** (`kAudioAggregateDeviceIsStackedKey == true`, `bplc` / "Stacked"): 把音频**同时输出**到多个设备 → 我们要的
///
/// 来源：完整迁移自 AudioTranscriber.OutputDeviceRouter.swift（仅 Notification 名变更）
@MainActor
public final class OutputDeviceRouter {
    public static let shared = OutputDeviceRouter()

    /// 记忆切换前的默认 system output device
    private var savedOutputDeviceID: AudioDeviceID?
    private var didRoute: Bool = false

    public struct OutputDevice: Identifiable, Hashable {
        public let id: AudioDeviceID
        public let name: String
        public let uid: String
        public let isMultiOutput: Bool
        public let subDeviceNames: [String]
    }

    // MARK: - 公共 API

    /// 列出所有「多输出设备」
    public func listMultiOutputDevices() -> [OutputDevice] {
        return listAllOutputDevices().filter { $0.isMultiOutput }
    }

    /// 列出所有输出设备
    public func listAllOutputDevices() -> [OutputDevice] {
        var devices: [OutputDevice] = []
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &ids)
        for deviceID in ids {
            guard hasOutputStreams(deviceID) else { continue }
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID) else { continue }
            let multi = isMultiOutputDevice(deviceID)
            let subs = multi ? subDeviceNames(of: deviceID) : []
            devices.append(OutputDevice(id: deviceID, name: name, uid: uid, isMultiOutput: multi, subDeviceNames: subs))
        }
        return devices
    }

    /// 当前默认 system output 设备
    public func currentDefaultOutput() -> OutputDevice? {
        let id = getDefaultOutputDevice()
        guard id != 0,
              let name = getDeviceName(id),
              let uid = getDeviceUID(id) else { return nil }
        let multi = isMultiOutputDevice(id)
        return OutputDevice(id: id, name: name, uid: uid, isMultiOutput: multi,
                            subDeviceNames: multi ? subDeviceNames(of: id) : [])
    }

    /// 路由到指定设备；保存当前默认输出
    @discardableResult
    public func route(to deviceID: AudioDeviceID) -> Bool {
        let current = getDefaultOutputDevice()
        if current == deviceID {
            didRoute = false
            savedOutputDeviceID = nil
            return true
        }
        savedOutputDeviceID = current
        let ok = setDefaultOutputDevice(deviceID)
        didRoute = ok
        if !ok { savedOutputDeviceID = nil }
        return ok
    }

    /// 还原为切换前的设备（如未切换则 no-op）
    @discardableResult
    public func restore() -> Bool {
        defer { didRoute = false; savedOutputDeviceID = nil }
        guard didRoute, let saved = savedOutputDeviceID else { return true }
        guard deviceExists(saved) else { return false }
        return setDefaultOutputDevice(saved)
    }

    /// 打开 Audio MIDI Setup 让用户去配置 Multi-Output Device
    public func openAudioMIDISetup() {
        #if canImport(AppKit)
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: - 内部：CoreAudio 操作

    private func getDefaultOutputDevice() -> AudioDeviceID {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        var sysAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &sysAddr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &id
        )
        return st == noErr
    }

    private func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sz) == noErr, sz > 0 else { return false }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, list) == noErr else { return false }
        var channels: UInt32 = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) { channels += buf.mNumberChannels }
        return channels > 0
    }

    private func deviceExists(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &ids)
        return ids.contains(deviceID)
    }

    /// 判断设备是否是「多输出设备」(stacked aggregate device)
    private func isMultiOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var classID: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        var classAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(deviceID, &classAddr, 0, nil, &size, &classID)
        guard classID == kAudioAggregateDeviceClassID else { return false }

        var dict: CFDictionary?
        var dictSize = UInt32(MemoryLayout<CFDictionary?>.size)
        var compAddr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let st = AudioObjectGetPropertyData(deviceID, &compAddr, 0, nil, &dictSize, &dict)
        guard st == noErr, let d = dict as? [String: Any] else { return false }
        if let stacked = d["stacked"] as? Bool, stacked { return true }
        if let stackedNum = d["stacked"] as? Int, stackedNum != 0 { return true }
        return false
    }

    private func subDeviceNames(of aggregateID: AudioDeviceID) -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyFullSubDeviceList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var arr: CFArray?
        var size = UInt32(MemoryLayout<CFArray?>.size)
        let st = AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, &arr)
        guard st == noErr, let uids = arr as? [String] else { return [] }
        let all = listAllOutputDevicesRaw()
        return uids.compactMap { uid in all.first(where: { $0.uid == uid })?.name }
    }

    private func listAllOutputDevicesRaw() -> [(id: AudioDeviceID, name: String, uid: String)] {
        var out: [(AudioDeviceID, String, String)] = []
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &ids)
        for id in ids {
            if let n = getDeviceName(id), let u = getDeviceUID(id) {
                out.append((id, n, u))
            }
        }
        return out
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name) == noErr else { return nil }
        return name as String?
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String?
    }
}
