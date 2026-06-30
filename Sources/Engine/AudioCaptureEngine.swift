import Foundation
import AVFoundation
import CoreAudio

// MARK: - 录制模式

/// 三种录制模式
enum RecordingMode: String, CaseIterable, Codable {
    case systemAudio   // A. 只录系统音频（声卡/环回设备）
    case microphone    // B. 只录麦克风
    case mix           // C. 系统音频 + 麦克风（双路并行 + ffmpeg amix 合并）

    var displayName: String {
        switch self {
        case .systemAudio: return "系统音频"
        case .microphone:  return "麦克风"
        case .mix:         return "系统音频 + 麦克风"
        }
    }

    var iconName: String {
        switch self {
        case .systemAudio: return "speaker.wave.2.fill"
        case .microphone:  return "mic.fill"
        case .mix:         return "person.wave.2.fill"
        }
    }
}

// MARK: - C 回调可访问的非隔离状态

/// 单路 AUHAL 渲染回调需要的非隔离数据
private final class CaptureState {
    var audioUnit: AudioUnit?
    var wavFile: UnsafeMutablePointer<FILE>?

    /// 预分配的渲染 buffer
    var renderBuffer: UnsafeMutablePointer<Float>?
    var renderBufferCapacity: Int = 0

    /// RMS 累积（C 回调写入，主线程定时读取）
    var rmsSum: Float = 0
    var rmsCount: Int = 0

    /// 累计采到的 frame 数（诊断 + 实时转写游标）
    var totalFrames: UInt64 = 0
    var callbackCount: UInt64 = 0
    var lastRenderError: OSStatus = 0
    var captureSampleRate: Double = 16000
    var flushCounter: UInt64 = 0

    /// 用于区分双路写入（仅日志/诊断使用）
    var tag: String = "main"

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
// 升级版：支持三种录制模式
//   - A. systemAudio：单路 AUHAL 采集环回设备（原有逻辑）
//   - B. microphone：单路 AUHAL 采集真实麦克风
//   - C. mix：双路并行采集，停止后 ffmpeg amix 合并

/// 录制引擎：支持系统音频 / 麦克风 / 混录三种模式
@MainActor
final class AudioCaptureEngine: ObservableObject {
    static let shared = AudioCaptureEngine()

    // MARK: - 公共状态

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var elapsedTime: TimeInterval = 0
    @Published var rmsLevel: Float = 0
    @Published var rmsHistory: [Float] = []

    /// 系统音频候选设备（环回 / 虚拟 / 聚合）
    @Published var availableSystemDevices: [AudioInputDevice] = []
    /// 麦克风候选设备（真实输入设备，排除环回）
    @Published var availableMicDevices: [AudioInputDevice] = []
    /// 兼容旧 UI：与 availableSystemDevices 一致
    var availableDevices: [AudioInputDevice] { availableSystemDevices }

    /// 当前选择的系统音频设备
    @Published var selectedSystemDevice: AudioInputDevice?
    /// 当前选择的麦克风设备
    @Published var selectedMicDevice: AudioInputDevice?
    /// 兼容旧 UI：等价于 selectedSystemDevice
    var selectedDevice: AudioInputDevice? {
        get { selectedSystemDevice }
        set { selectedSystemDevice = newValue }
    }

    @Published var noDevicesFound = false

    /// 当前录制模式
    @Published var recordingMode: RecordingMode = {
        if let raw = UserDefaults.standard.string(forKey: "AudioNote.recordingMode"),
           let mode = RecordingMode(rawValue: raw) {
            return mode
        }
        return .systemAudio
    }() {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: "AudioNote.recordingMode") }
    }

    /// 混录时系统音频增益（0.0 ~ 2.0，UI 0%~200%）
    @Published var mixSystemGain: Float = Float(UserDefaults.standard.object(forKey: "AudioNote.mixSystemGain") as? Double ?? 1.0) {
        didSet { UserDefaults.standard.set(Double(mixSystemGain), forKey: "AudioNote.mixSystemGain") }
    }
    /// 混录时麦克风增益（0.0 ~ 2.0）
    @Published var mixMicGain: Float = Float(UserDefaults.standard.object(forKey: "AudioNote.mixMicGain") as? Double ?? 1.0) {
        didSet { UserDefaults.standard.set(Double(mixMicGain), forKey: "AudioNote.mixMicGain") }
    }
    /// 混录后是否保留原始两路（默认关，合并后删）
    @Published var keepOriginalTracks: Bool = UserDefaults.standard.bool(forKey: "AudioNote.keepOriginalTracks") {
        didSet { UserDefaults.standard.set(keepOriginalTracks, forKey: "AudioNote.keepOriginalTracks") }
    }

    // MARK: - 输出路由（仅系统音频/混录模式生效）

    @Published var autoRouteSystemOutput: Bool = true
    @Published var preferredMultiOutputDeviceID: AudioDeviceID?
    @Published var lastRouteMessage: String?
    @Published var activeMultiOutputName: String?

    // MARK: - 静音自动停止

    @Published var silenceSeconds: TimeInterval = 0
    @Published var silenceAutoStopEnabled: Bool = true
    var silenceLevelThreshold: Float = 0.02
    @Published var silenceTimeoutSec: TimeInterval = 300
    var onSilenceTimeout: (() -> Void)?

    // MARK: - 内部

    private let systemState = CaptureState()
    private let micState = CaptureState()
    private var systemFileURL: URL?
    private var micFileURL: URL?
    private var finalFileURL: URL?
    private var timer: Timer?
    private var recordingStart = Date()
    private var pausedDuration: TimeInterval = 0
    private var pauseStart: Date?
    private let maxHistoryPoints = 300

    /// 最近一次录音的"最终"文件 URL（A/B 直接=采集 wav；C=合并后的 mix wav 或采集中的 systemFile）
    @Published private(set) var recordingFileURL: URL?

    /// 通用音频输入设备模型（既能装环回，也能装麦克风）
    struct AudioInputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let isLoopback: Bool

        var displayName: String {
            if isLoopback, name.lowercased().contains("blackhole") {
                return "BlackHole（系统音频）"
            }
            return name
        }
    }

    // 兼容旧引用名
    typealias LoopbackDevice = AudioInputDevice

    init() {}

    // MARK: - 录音保存目录

    static let recordingsDirectoryPathKey = "AudioNote.recordingsDirectoryPath"
    static let recordingsDirectoryDefaultsChanged = Notification.Name("AudioNote.recordingsDirectoryChanged")

    static var defaultRecordingsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/AudioNote/Recordings")
    }

    var recordingsDirectory: URL {
        let url = AudioCaptureEngine.resolveRecordingsDirectory()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func resolveRecordingsDirectory() -> URL {
        if let saved = UserDefaults.standard.string(forKey: recordingsDirectoryPathKey),
           !saved.isEmpty {
            return URL(fileURLWithPath: (saved as NSString).expandingTildeInPath)
        }
        return defaultRecordingsDirectory
    }

    func setRecordingsDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: AudioCaptureEngine.recordingsDirectoryPathKey)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        objectWillChange.send()
        NotificationCenter.default.post(name: AudioCaptureEngine.recordingsDirectoryDefaultsChanged, object: nil)
    }

    func resetRecordingsDirectory() {
        UserDefaults.standard.removeObject(forKey: AudioCaptureEngine.recordingsDirectoryPathKey)
        objectWillChange.send()
        NotificationCenter.default.post(name: AudioCaptureEngine.recordingsDirectoryDefaultsChanged, object: nil)
    }

    // MARK: - 设备扫描

    /// 当前已采集的总帧数（实时转写游标用；混录时返回系统音频那一路）
    var capturedFrames: UInt64 {
        recordingMode == .microphone ? micState.totalFrames : systemState.totalFrames
    }
    /// 当前采集采样率（实时转写用）
    var captureSampleRate: Double {
        recordingMode == .microphone ? micState.captureSampleRate : systemState.captureSampleRate
    }

    func refreshDevices() {
        var systemDevices: [AudioInputDevice] = []
        var micDevices: [AudioInputDevice] = []

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
            guard let name = getDeviceName(deviceID),
                  let uid = getDeviceUID(deviceID),
                  inputChannels(deviceID) > 0 else { continue }

            let loopback = isLoopbackByName(name)
            let dev = AudioInputDevice(id: deviceID, name: name, uid: uid, isLoopback: loopback)
            if loopback {
                systemDevices.append(dev)
            } else {
                micDevices.append(dev)
            }
        }

        availableSystemDevices = systemDevices
        availableMicDevices = micDevices
        noDevicesFound = systemDevices.isEmpty && micDevices.isEmpty

        if selectedSystemDevice == nil || !systemDevices.contains(where: { $0.id == selectedSystemDevice?.id }) {
            selectedSystemDevice = systemDevices.first
        }
        if selectedMicDevice == nil || !micDevices.contains(where: { $0.id == selectedMicDevice?.id }) {
            // 优先选系统默认输入设备
            selectedMicDevice = defaultInputDevice(in: micDevices) ?? micDevices.first
        }
    }

    private func defaultInputDevice(in pool: [AudioInputDevice]) -> AudioInputDevice? {
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &defaultID) == noErr else {
            return nil
        }
        return pool.first(where: { $0.id == defaultID })
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

    private func inputChannels(_ deviceID: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var sz: UInt32 = 0
        AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &sz)
        guard sz > 0 else { return 0 }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &sz, list) == noErr else { return 0 }
        var ch: UInt32 = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) { ch += buf.mNumberChannels }
        return ch
    }

    private func isLoopbackByName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["blackhole", "loopback", "soundflower", "virtual", "aggregate", "multi-output"]
            .contains(where: { lower.contains($0) })
    }

    // MARK: - 录制控制（入口）

    func startRecording() {
        guard !isRecording else {
            Logger.recording.warn("startRecording 中止：isRecording=true")
            return
        }

        switch recordingMode {
        case .systemAudio:
            startSystemAudioOnly()
        case .microphone:
            startMicrophoneOnly()
        case .mix:
            startMix()
        }
    }

    private func startSystemAudioOnly() {
        guard let device = selectedSystemDevice else {
            Logger.recording.warn("systemAudio 模式启动失败：未选择系统音频设备")
            return
        }
        attemptRouteSystemOutput()

        let filename = "\(stampFmt.string(from: Date())).wav"
        let url = recordingsDirectory.appendingPathComponent(filename)
        systemFileURL = url
        micFileURL = nil
        finalFileURL = url
        recordingFileURL = url

        guard openAUHAL(state: systemState, device: device, fileURL: url, tag: "sys") else {
            cleanupSession(removeFiles: true)
            return
        }
        beginTickAndState()
        Logger.recording.info("录制开始 [systemAudio]: \(filename)")
    }

    private func startMicrophoneOnly() {
        guard let device = selectedMicDevice else {
            Logger.recording.warn("microphone 模式启动失败：未选择麦克风")
            return
        }
        // 麦克风模式不需要路由系统输出
        activeMultiOutputName = nil
        lastRouteMessage = nil

        let filename = "\(stampFmt.string(from: Date()))-mic.wav"
        let url = recordingsDirectory.appendingPathComponent(filename)
        systemFileURL = nil
        micFileURL = url
        finalFileURL = url
        recordingFileURL = url

        guard openAUHAL(state: micState, device: device, fileURL: url, tag: "mic") else {
            cleanupSession(removeFiles: true)
            return
        }
        beginTickAndState()
        Logger.recording.info("录制开始 [microphone]: \(filename)")
    }

    private func startMix() {
        guard let sysDev = selectedSystemDevice else {
            Logger.recording.warn("mix 模式启动失败：未选择系统音频设备")
            return
        }
        guard let micDev = selectedMicDevice else {
            Logger.recording.warn("mix 模式启动失败：未选择麦克风")
            return
        }
        attemptRouteSystemOutput()

        let stamp = stampFmt.string(from: Date())
        let sysURL = recordingsDirectory.appendingPathComponent("\(stamp)-sys.wav")
        let micURL = recordingsDirectory.appendingPathComponent("\(stamp)-mic.wav")
        let mixURL = recordingsDirectory.appendingPathComponent("\(stamp)-mix.wav")

        systemFileURL = sysURL
        micFileURL = micURL
        finalFileURL = mixURL
        // 实时转写跟随系统音频路：录制中 recordingFileURL 指向 sys，停止后切换到 mix
        recordingFileURL = sysURL

        guard openAUHAL(state: systemState, device: sysDev, fileURL: sysURL, tag: "sys") else {
            cleanupSession(removeFiles: true)
            return
        }
        guard openAUHAL(state: micState, device: micDev, fileURL: micURL, tag: "mic") else {
            // 回滚系统路
            stopAUHAL(state: systemState)
            cleanupSession(removeFiles: true)
            return
        }
        beginTickAndState()
        Logger.recording.info("录制开始 [mix]: sys=\(sysURL.lastPathComponent) mic=\(micURL.lastPathComponent)")
    }

    private func beginTickAndState() {
        isRecording = true; isPaused = false
        recordingStart = Date(); pausedDuration = 0
        rmsHistory = []
        silenceSeconds = 0

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 打开并启动一个 AUHAL 单元，绑定指定设备和文件
    private func openAUHAL(state: CaptureState, device: AudioInputDevice, fileURL: URL, tag: String) -> Bool {
        state.tag = tag

        let wav = fopen(fileURL.path, "wb")
        guard let wav = wav else {
            Logger.recording.error("[\(tag)] 无法创建录音文件: \(fileURL.path)")
            return false
        }
        state.wavFile = wav

        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &acd) else {
            Logger.recording.error("[\(tag)] AudioComponentFindNext failed")
            fclose(wav); state.wavFile = nil; return false
        }
        var au: AudioUnit?
        let newStatus = AudioComponentInstanceNew(comp, &au)
        guard newStatus == noErr, let audioUnit = au else {
            Logger.recording.error("[\(tag)] AudioComponentInstanceNew failed: \(newStatus)")
            fclose(wav); state.wavFile = nil; return false
        }

        var enable: UInt32 = 1
        var disable: UInt32 = 0
        var s: OSStatus
        s = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        Logger.recording.info("[\(tag)] EnableIO Input: \(s)")
        s = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size))
        Logger.recording.info("[\(tag)] EnableIO Output: \(s)")
        var deviceID = device.id
        s = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        Logger.recording.info("[\(tag)] SetCurrentDevice id=\(deviceID) name=\(device.name) status=\(s)")

        var inputASBD = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1, &inputASBD, &asbdSize)
        Logger.recording.info("[\(tag)] Device native format: sr=\(inputASBD.mSampleRate) ch=\(inputASBD.mChannelsPerFrame)")

        let nativeSR = inputASBD.mSampleRate > 0 ? inputASBD.mSampleRate : 48000
        var asbd = AudioStreamBasicDescription(
            mSampleRate: nativeSR, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        s = AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        Logger.recording.info("[\(tag)] SetStreamFormat output status=\(s) sr=\(nativeSR)")
        state.captureSampleRate = nativeSR

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
        Logger.recording.info("[\(tag)] Init=\(initStatus) Start=\(startStatus)")
        guard initStatus == noErr, startStatus == noErr else {
            fclose(wav); state.wavFile = nil
            state.audioUnit = nil
            return false
        }

        // 重置计数器
        state.rmsSum = 0; state.rmsCount = 0
        state.totalFrames = 0
        state.callbackCount = 0
        state.lastRenderError = 0
        state.flushCounter = 0
        return true
    }

    private func stopAUHAL(state: CaptureState) {
        if let au = state.audioUnit {
            AudioOutputUnitStop(au); AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
        state.audioUnit = nil
        if let f = state.wavFile { fclose(f); state.wavFile = nil }
    }

    func pauseRecording() {
        guard isRecording, !isPaused else { return }
        if let au = systemState.audioUnit { AudioOutputUnitStop(au) }
        if let au = micState.audioUnit { AudioOutputUnitStop(au) }
        isPaused = true
        pauseStart = Date()
    }

    func resumeRecording() {
        guard isRecording, isPaused else { return }
        if let au = systemState.audioUnit { AudioOutputUnitStart(au) }
        if let au = micState.audioUnit { AudioOutputUnitStart(au) }
        if let start = pauseStart {
            pausedDuration += Date().timeIntervalSince(start)
        }
        isPaused = false
        silenceSeconds = 0
    }

    @discardableResult
    func stopRecording() -> URL? {
        guard isRecording else { return nil }
        timer?.invalidate(); timer = nil

        // 停止双路 AUHAL
        let usedSystem = systemState.audioUnit != nil
        let usedMic = micState.audioUnit != nil
        stopAUHAL(state: systemState)
        stopAUHAL(state: micState)

        // 回填 WAV header
        if usedSystem, let url = systemFileURL {
            updateWAVHeader(url, sampleRate: UInt32(systemState.captureSampleRate))
        }
        if usedMic, let url = micFileURL {
            updateWAVHeader(url, sampleRate: UInt32(micState.captureSampleRate))
        }

        restoreSystemOutput()

        Logger.recording.info("诊断 sys: cb=\(systemState.callbackCount) frames=\(systemState.totalFrames) err=\(systemState.lastRenderError) sr=\(systemState.captureSampleRate)")
        Logger.recording.info("诊断 mic: cb=\(micState.callbackCount) frames=\(micState.totalFrames) err=\(micState.lastRenderError) sr=\(micState.captureSampleRate)")

        let elapsedNow = elapsedTime
        isRecording = false; isPaused = false; rmsLevel = 0

        // 太短直接清理
        if elapsedNow < 1 {
            cleanupSession(removeFiles: true)
            return nil
        }

        // 模式分流
        switch recordingMode {
        case .systemAudio:
            let url = systemFileURL
            systemFileURL = nil; finalFileURL = nil
            if let url = url, FileManager.default.fileExists(atPath: url.path) {
                Logger.recording.info("停止 [systemAudio]: \(url.lastPathComponent)")
                recordingFileURL = url
                return url
            }
            recordingFileURL = nil
            return nil

        case .microphone:
            let url = micFileURL
            micFileURL = nil; finalFileURL = nil
            if let url = url, FileManager.default.fileExists(atPath: url.path) {
                Logger.recording.info("停止 [microphone]: \(url.lastPathComponent)")
                recordingFileURL = url
                return url
            }
            recordingFileURL = nil
            return nil

        case .mix:
            guard let sysURL = systemFileURL,
                  let micURL = micFileURL,
                  let mixURL = finalFileURL else {
                Logger.recording.error("mix 停止异常：缺少必要 URL")
                cleanupSession(removeFiles: true)
                return nil
            }
            // 同步混音（阻塞但耗时短，<2s 对几分钟录音；为简单起见走主线程）
            let sysGain = mixSystemGain
            let micGain = mixMicGain
            let keepOriginals = keepOriginalTracks
            let ok = AudioMixer.merge(systemURL: sysURL, systemGain: sysGain,
                                       micURL: micURL, micGain: micGain,
                                       outputURL: mixURL)
            systemFileURL = nil; micFileURL = nil; finalFileURL = nil

            if ok, FileManager.default.fileExists(atPath: mixURL.path) {
                if !keepOriginals {
                    try? FileManager.default.removeItem(at: sysURL)
                    try? FileManager.default.removeItem(at: micURL)
                }
                Logger.recording.info("停止 [mix]: 合并完成 -> \(mixURL.lastPathComponent)")
                recordingFileURL = mixURL
                return mixURL
            } else {
                Logger.recording.error("mix 合并失败，回退到系统音频 wav 作为最终产物")
                // 合并失败兜底：用 sys.wav 作为最终结果，删 mic
                try? FileManager.default.removeItem(at: micURL)
                if FileManager.default.fileExists(atPath: sysURL.path) {
                    recordingFileURL = sysURL
                    return sysURL
                }
                recordingFileURL = nil
                return nil
            }
        }
    }

    /// 异常路径清理
    private func cleanupSession(removeFiles: Bool) {
        timer?.invalidate(); timer = nil
        stopAUHAL(state: systemState)
        stopAUHAL(state: micState)
        if removeFiles {
            if let url = systemFileURL { try? FileManager.default.removeItem(at: url) }
            if let url = micFileURL { try? FileManager.default.removeItem(at: url) }
        }
        systemFileURL = nil; micFileURL = nil; finalFileURL = nil
        recordingFileURL = nil
        isRecording = false; isPaused = false
    }

    // MARK: - 便捷方法

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

    // MARK: - 内部 tick

    private func tick() {
        guard isRecording, !isPaused else { return }
        elapsedTime = Date().timeIntervalSince(recordingStart) - pausedDuration

        // RMS 取决于当前主活动路：mix/systemAudio 以系统路为准；microphone 用 mic 路
        let primaryState = (recordingMode == .microphone) ? micState : systemState
        let avg = primaryState.drainRMS()
        // 另一路也排空，避免 RMS 无限累积
        if recordingMode == .mix { _ = micState.drainRMS() }

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

    // MARK: - WAV header

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

    private let stampFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "MMddHHmmss"
        return f
    }()
}

extension Notification.Name {
    static let audioNoteMultiOutputMissing = Notification.Name("AudioNote.MultiOutputMissing")
}

// MARK: - AudioUnit 渲染回调（统一）

private func audioRenderCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
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
        return noErr
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
