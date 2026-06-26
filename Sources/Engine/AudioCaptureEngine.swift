import Foundation
import AVFoundation
import CoreAudio

// MARK: - C 回调可访问的非隔离状态

/// AudioUnit 渲染回调需要的非隔离数据（不归 MainActor 管）
private final class CaptureState {
    var audioUnit: AudioUnit?
    var wavFile: UnsafeMutablePointer<FILE>?

    /// 预分配的渲染 buffer（避免 AudioUnitRender 分配失败）
    var renderBuffer: UnsafeMutablePointer<Float>?
    var renderBufferCapacity: Int = 0

    /// RMS 累积（C 回调写入，主线程定时读取）
    var rmsSum: Float = 0
    var rmsCount: Int = 0

    /// 累计采到的 frame 数（诊断用）
    var totalFrames: UInt64 = 0
    /// 渲染回调被调用次数
    var callbackCount: UInt64 = 0
    /// 最近一次 render error
    var lastRenderError: OSStatus = 0
    /// 实际采集采样率
    var captureSampleRate: Double = 16000
    /// fflush 计数器
    var flushCounter: UInt64 = 0

    func addRMS(_ rms: Float) {
        rmsSum += rms
        rmsCount += 1
    }

    func drainRMS() -> Float {
        guard rmsCount > 0 else { return 0 }
        let avg = rmsSum / Float(rmsCount)
        rmsSum = 0
        rmsCount = 0
        return avg
    }

    func ensureBuffer(_ frames: Int) -> UnsafeMutablePointer<Float> {
        if frames > renderBufferCapacity {
            renderBuffer?.deallocate()
            renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            renderBufferCapacity = frames
        }
        return renderBuffer!
    }

    deinit {
        if let f = wavFile { fclose(f) }
        renderBuffer?.deallocate()
    }
}

// MARK: - AudioCaptureEngine
//
// 完整迁移自 AudioTranscriber.AudioRecorder（AUHAL 系统音频采集引擎）。
// 适配 UniAudio/AudioNote：
//   - 类名固定为 `AudioCaptureEngine` 以保持现有 UI/SettingsView/RecordView 兼容
//   - 提供 `static let shared` 单例（UI 依赖）
//   - 路径默认 `~/Documents/AudioNote/Recordings`
//   - UserDefaults Key 改为 `AudioNote.recordingsDirectoryPath`
//   - Notification 名 `audioNoteMultiOutputMissing`
//   - 日志改走 `Logger.recording`（替代 `print("[AudioRecorder]...")`)
//   - 保留 `formattedElapsed()` 便捷方法供 RecordView

/// 系统音频采集引擎：使用原生 AudioUnit (AUHAL) 直接绑定 loopback 设备。
@MainActor
final class AudioCaptureEngine: ObservableObject {
    static let shared = AudioCaptureEngine()

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var rmsLevel: Float = 0
    @Published var rmsHistory: [Float] = []
    @Published var availableDevices: [LoopbackDevice] = []
    @Published var selectedDevice: LoopbackDevice?
    @Published var noDevicesFound = false

    /// 录制时是否自动切换系统输出到 Multi-Output Device（默认开）
    @Published var autoRouteSystemOutput: Bool = true
    /// 用户选择的 Multi-Output 目标设备；nil 表示自动挑第一个
    @Published var preferredMultiOutputDeviceID: AudioDeviceID?
    /// 上次路由结果（供 UI 展示提示）
    @Published var lastRouteMessage: String?
    /// 当前路由到的多输出设备名（录制中显示）
    @Published var activeMultiOutputName: String?

    // MARK: - 静音自动停止

    /// 当前持续静音时长（秒）
    @Published var silenceSeconds: TimeInterval = 0
    /// 启用"静音超时自动停止"
    @Published var silenceAutoStopEnabled: Bool = true
    /// 静音判定 RMS 阈值（线性，~-34dBFS）
    var silenceLevelThreshold: Float = 0.02
    /// 超过多少秒静音触发自动停止（默认 5 分钟 = 300s）
    @Published var silenceTimeoutSec: TimeInterval = 300
    /// 触发静音超时时的回调
    var onSilenceTimeout: (() -> Void)?

    private let state = CaptureState()
    private var currentFileURL: URL?
    private var timer: Timer?
    private var recordingStart = Date()
    private var pausedDuration: TimeInterval = 0
    private var pauseStart: Date?
    private let maxHistoryPoints = 300

    /// 最近一次录音文件 URL（录音中=当前正在写入的；停止后=最后一次完成的录音）
    @Published private(set) var recordingFileURL: URL?

    struct LoopbackDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        var displayName: String {
            name.lowercased().contains("blackhole") ? "BlackHole（系统音频）" : name
        }
    }

    // MARK: - 录音/转写文件保存目录（用户可配置）

    static let recordingsDirectoryPathKey = "AudioNote.recordingsDirectoryPath"
    static let recordingsDirectoryDefaultsChanged = Notification.Name("AudioNote.recordingsDirectoryChanged")

    /// 默认的录音/转写保存目录（无任何持久化时使用）
    static var defaultRecordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioNote/Recordings")
    }

    /// 当前生效的录音/转写保存目录
    var recordingsDirectory: URL {
        let url = AudioCaptureEngine.resolveRecordingsDirectory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 不创建目录、纯路径解析（供 UI 展示用）
    static func resolveRecordingsDirectory() -> URL {
        if let saved = UserDefaults.standard.string(forKey: recordingsDirectoryPathKey),
           !saved.isEmpty {
            return URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
        }
        return defaultRecordingsDirectory
    }

    /// 修改保存目录（同时持久化到 UserDefaults 并广播通知）
    func setRecordingsDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: AudioCaptureEngine.recordingsDirectoryPathKey)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        objectWillChange.send()
        NotificationCenter.default.post(name: AudioCaptureEngine.recordingsDirectoryDefaultsChanged, object: nil)
    }

    /// 重置为默认（清除持久化）
    func resetRecordingsDirectory() {
        UserDefaults.standard.removeObject(forKey: AudioCaptureEngine.recordingsDirectoryPathKey)
        objectWillChange.send()
        NotificationCenter.default.post(name: AudioCaptureEngine.recordingsDirectoryDefaultsChanged, object: nil)
    }

    // MARK: - 设备扫描

    /// 当前已采集的总帧数（基于真实采样率），供实时滑窗转写读取游标
    var capturedFrames: UInt64 { state.totalFrames }
    /// 当前采集采样率
    var captureSampleRate: Double { state.captureSampleRate }

    func refreshDevices() {
        var devices: [LoopbackDevice] = []
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize)
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &propSize, &ids)
        for deviceID in ids {
            if let name = getDeviceName(deviceID),
               let uid = getDeviceUID(deviceID),
               isLoopbackDevice(deviceID, name: name) {
                devices.append(LoopbackDevice(id: deviceID, name: name, uid: uid))
            }
        }
        availableDevices = devices
        noDevicesFound = devices.isEmpty
        if selectedDevice == nil || !devices.contains(where: { $0.id == selectedDevice?.id }) {
            selectedDevice = devices.first
        }
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
    private func isLoopbackDevice(_ deviceID: AudioDeviceID, name: String) -> Bool {
        let lower = name.lowercased()
        guard ["blackhole", "loopback", "soundflower", "virtual", "aggregate", "multi-output"]
            .contains(where: { lower.contains($0) }) else { return false }
        var channels: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sz)
        guard sz > 0 else { return false }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { list.deallocate() }
        AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, list)
        for buf in UnsafeMutableAudioBufferListPointer(list) { channels += buf.mNumberChannels }
        return channels > 0
    }

    // MARK: - 录制控制

    func startRecording() {
        guard !isRecording, let device = selectedDevice else {
            Logger.recording.warn("startRecording 中止：isRecording=\(isRecording) selectedDevice=\(selectedDevice?.name ?? "nil")")
            return
        }

        // 在打开 AudioUnit 之前先做输出路由（避免抢设备引起 glitch）
        attemptRouteSystemOutput()

        // 统一命名规则：MMDDHHMMSS.wav
        let filename = "\(stampFmt.string(from: Date())).wav"
        let url = recordingsDirectory.appendingPathComponent(filename)
        currentFileURL = url
        recordingFileURL = url

        let wav = fopen(url.path, "wb")
        guard let wav = wav else {
            Logger.recording.error("无法创建录音文件: \(url.path)")
            return
        }
        state.wavFile = wav

        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &acd) else {
            Logger.recording.error("AudioComponentFindNext failed")
            fclose(wav); state.wavFile = nil; return
        }
        var au: AudioUnit?
        let newStatus = AudioComponentInstanceNew(comp, &au)
        guard newStatus == noErr, let audioUnit = au else {
            Logger.recording.error("AudioComponentInstanceNew failed: \(newStatus)")
            fclose(wav); state.wavFile = nil; return
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var s: OSStatus
        s = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        Logger.recording.info("EnableIO Input: \(s)")
        s = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        Logger.recording.info("EnableIO Output: \(s)")
        var deviceID = device.id
        s = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        Logger.recording.info("SetCurrentDevice id=\(deviceID) name=\(device.name) status=\(s)")

        // 查询输入设备的实际格式（采样率），AUHAL 不会自动重采样输入
        var inputASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1, &inputASBD, &asbdSize)
        Logger.recording.info("Device native format: sr=\(inputASBD.mSampleRate) ch=\(inputASBD.mChannelsPerFrame)")

        // 输出格式：保持设备原生采样率，单声道 float32（让 AUHAL 做声道下混）
        let nativeSR = inputASBD.mSampleRate > 0 ? inputASBD.mSampleRate : 48000
        var asbd = AudioStreamBasicDescription(
            mSampleRate: nativeSR, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        s = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        Logger.recording.info("SetStreamFormat output status=\(s) sr=\(nativeSR)")
        state.captureSampleRate = nativeSR

        // 现在已知真实采样率，写正确的 WAV header（边录边转的脚本会读取）
        writeWAVHeader(wav, dataSize: 0, sampleRate: UInt32(nativeSR))
        fflush(wav)

        state.audioUnit = audioUnit

        let selfPtr = Unmanaged.passUnretained(state).toOpaque()
        var cb = AURenderCallbackStruct(
            inputProc: audioRenderCallback,
            inputProcRefCon: selfPtr
        )
        AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let initStatus = AudioUnitInitialize(audioUnit)
        let startStatus = AudioOutputUnitStart(audioUnit)
        Logger.recording.info("Init=\(initStatus) Start=\(startStatus)")
        guard initStatus == noErr, startStatus == noErr else {
            fclose(wav); state.wavFile = nil
            state.audioUnit = nil; return
        }

        isRecording = true; isPaused = false
        recordingStart = Date(); pausedDuration = 0
        rmsHistory = []; state.rmsSum = 0; state.rmsCount = 0
        silenceSeconds = 0
        // 关键：重置帧/回调计数，否则同进程内第二次录制 frame 游标会沿用第一次的累积值，
        // 导致 ASR 滑窗用错误的 start/end-frame 去切 wav，partial 转写全程为空
        state.totalFrames = 0
        state.callbackCount = 0
        state.lastRenderError = 0
        state.flushCounter = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Logger.recording.info("录制开始: \(filename)")
    }

    func pauseRecording() {
        guard isRecording, !isPaused, let au = state.audioUnit else { return }
        AudioOutputUnitStop(au); isPaused = true; pauseStart = Date()
    }

    func resumeRecording() {
        guard isRecording, isPaused, let au = state.audioUnit else { return }
        AudioOutputUnitStart(au); pausedDuration += Date().timeIntervalSince(pauseStart!); isPaused = false
        silenceSeconds = 0
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate(); timer = nil
        if let au = state.audioUnit {
            AudioOutputUnitStop(au); AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        state.audioUnit = nil

        if let f = state.wavFile { fclose(f); state.wavFile = nil }
        if let cu = currentFileURL {
            updateWAVHeader(cu, sampleRate: UInt32(state.captureSampleRate))
        }

        // 还原系统输出（如果之前切过）
        restoreSystemOutput()

        Logger.recording.info("诊断: callbacks=\(state.callbackCount) frames=\(state.totalFrames) lastErr=\(state.lastRenderError) sr=\(state.captureSampleRate)")

        let url = currentFileURL; currentFileURL = nil
        isRecording = false; isPaused = false; rmsLevel = 0

        if elapsedTime < 1, let url = url {
            try? FileManager.default.removeItem(at: url)
            recordingFileURL = nil
            return nil
        }
        if let url = url, FileManager.default.fileExists(atPath: url.path) {
            let sz = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            Logger.recording.info("停止: \(url.lastPathComponent) (\(sz/1024)KB, \(Int(elapsedTime))s)")
            recordingFileURL = url
            return url
        }
        recordingFileURL = nil
        return nil
    }

    // MARK: - 便捷方法（兼容 UniAudio 现有 UI）

    /// `MM:SS` 或 `H:MM:SS` 格式
    func formattedElapsed() -> String {
        let t = Int(elapsedTime)
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - 内部

    private func tick() {
        guard isRecording, !isPaused else { return }
        elapsedTime = Date().timeIntervalSince(recordingStart) - pausedDuration
        let avg = state.drainRMS()
        if avg > 0 {
            let dbfs = 20 * log10(max(avg, 1e-10))
            rmsLevel = max(0, min(1, (dbfs + 50) / 50))
            rmsHistory.append(rmsLevel)
            if rmsHistory.count > maxHistoryPoints {
                rmsHistory.removeFirst(rmsHistory.count - maxHistoryPoints)
            }
            if avg < silenceLevelThreshold {
                silenceSeconds += 0.05
            } else {
                silenceSeconds = 0
            }
        } else {
            silenceSeconds += 0.05
        }
        if silenceAutoStopEnabled, silenceSeconds >= silenceTimeoutSec {
            Logger.recording.info("静音超时 \(Int(silenceSeconds))s，触发自动停止")
            silenceSeconds = 0
            onSilenceTimeout?()
        }
    }

    private func writeWAVHeader(_ file: UnsafeMutablePointer<FILE>, dataSize: UInt32, sampleRate: UInt32) {
        let sr = sampleRate, ch: UInt16 = 1, bps: UInt16 = 16
        let br = sr * UInt32(ch) * UInt32(bps / 8), ba = ch * (bps / 8)
        func w(_ v: UInt32) { var x = v.littleEndian; fwrite(&x, 4, 1, file) }
        func w2(_ v: UInt16) { var x = v.littleEndian; fwrite(&x, 2, 1, file) }
        fwrite("RIFF", 1, 4, file); w(36 + dataSize)
        fwrite("WAVE", 1, 4, file)
        fwrite("fmt ", 1, 4, file); w(16)
        w2(1); w2(ch); w(sr); w(br); w2(ba); w2(bps)
        fwrite("data", 1, 4, file); w(dataSize)
    }

    private func updateWAVHeader(_ url: URL, sampleRate: UInt32) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attrs[.size] as? Int, fileSize > 44 else { return }
        let ds = UInt32(fileSize - 44)
        guard let fh = FileHandle(forUpdatingAtPath: url.path) else { return }
        defer { try? fh.close() }
        var rs = (36 + ds).littleEndian; fh.seek(toFileOffset: 4); fh.write(Data(bytes: &rs, count: 4))
        var sr = sampleRate.littleEndian; fh.seek(toFileOffset: 24); fh.write(Data(bytes: &sr, count: 4))
        var br = (sampleRate * 2).littleEndian; fh.seek(toFileOffset: 28); fh.write(Data(bytes: &br, count: 4))
        var dd = ds.littleEndian; fh.seek(toFileOffset: 40); fh.write(Data(bytes: &dd, count: 4))
    }

    // MARK: - 系统输出路由

    /// 录制开始时尝试将系统输出切到多输出设备
    private func attemptRouteSystemOutput() {
        guard autoRouteSystemOutput else {
            lastRouteMessage = nil
            activeMultiOutputName = nil
            return
        }
        let router = OutputDeviceRouter.shared
        let multiOuts = router.listMultiOutputDevices()
        guard !multiOuts.isEmpty else {
            lastRouteMessage = "未检测到多输出设备；建议在「音频 MIDI 设置」中创建一个，否则耳机将听不到声音。"
            activeMultiOutputName = nil
            NotificationCenter.default.post(name: .audioNoteMultiOutputMissing, object: nil)
            return
        }
        let target: OutputDeviceRouter.OutputDevice = {
            if let pref = preferredMultiOutputDeviceID,
               let m = multiOuts.first(where: { $0.id == pref }) { return m }
            if let m = multiOuts.first(where: { $0.subDeviceNames.contains(where: { $0.lowercased().contains("blackhole") }) }) {
                return m
            }
            return multiOuts[0]
        }()
        let ok = router.route(to: target.id)
        if ok {
            activeMultiOutputName = target.name
            lastRouteMessage = "系统输出已切到「\(target.name)」"
            Logger.recording.info("输出路由 → \(target.name)")
        } else {
            activeMultiOutputName = nil
            lastRouteMessage = "切换系统输出失败"
        }
    }

    /// 停止录制时还原系统输出
    private func restoreSystemOutput() {
        let router = OutputDeviceRouter.shared
        if router.restore() {
            if activeMultiOutputName != nil {
                Logger.recording.info("输出路由已还原")
            }
        }
        activeMultiOutputName = nil
        lastRouteMessage = nil
    }

    /// 统一文件命名时间戳：MMDDHHMMSS（10 位）
    private let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMddHHmmss"
        return f
    }()
}

extension Notification.Name {
    /// 录制启动时未发现 Multi-Output Device，UI 应弹引导
    static let audioNoteMultiOutputMissing = Notification.Name("AudioNote.MultiOutputMissing")
}

// MARK: - AudioUnit 渲染回调

private func audioRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // 注意：对于 input AudioUnit，ioData 通常是 NULL，必须我们自己构造 buffer list
    let state = Unmanaged<CaptureState>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let au = state.audioUnit else { return noErr }

    let fc = Int(inNumberFrames)
    let buffer = state.ensureBuffer(fc)

    var bufferList = AudioBufferList(
        mNumberBuffers: 1,
        mBuffers: AudioBuffer(
            mNumberChannels: 1,
            mDataByteSize: inNumberFrames * 4,
            mData: UnsafeMutableRawPointer(buffer)
        )
    )

    state.callbackCount &+= 1
    let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
    guard status == noErr else {
        state.lastRenderError = status
        return noErr  // 返回 noErr 不阻断后续回调
    }

    state.totalFrames &+= UInt64(fc)

    var sum: Float = 0
    for i in 0..<fc { sum += buffer[i] * buffer[i] }
    let rms = sqrt(sum / Float(fc))
    state.addRMS(rms)

    if let file = state.wavFile {
        var int16Samples = [Int16](repeating: 0, count: fc)
        for i in 0..<fc {
            int16Samples[i] = Int16(max(-1.0, min(1.0, buffer[i])) * 32767.0)
        }
        int16Samples.withUnsafeBytes { _ = fwrite($0.baseAddress, 1, $0.count, file) }
        state.flushCounter &+= 1
        if state.flushCounter % 50 == 0 {
            fflush(file)
        }
    }

    return noErr
}
