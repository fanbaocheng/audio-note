import SwiftUI
import AudioNoteCore

/// 录制中心 — 声卡环回录制控制 + 实时波形 + 流式转写预览
struct RecordView: View {
    @EnvironmentObject var recorder: AudioCaptureEngine
    @EnvironmentObject var asr: ASRService
    @EnvironmentObject var scheduler: TaskScheduler
    @State private var showDevicePicker: Bool = false
    @State private var showModePicker: Bool = false

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            // 顶部：模式选择 + 设备选择 + 静音设置
            HStack(spacing: DS.Spacing.sm) {
                modeSelectorPill
                deviceSelectorPill
                Spacer()
                Toggle("静音自动停止", isOn: $recorder.silenceAutoStopEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.caption)
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.top, DS.Spacing.md)

            // 中部：录制控制 + 波形（2:3 比例）
            GeometryReader { geo in
                let gap = DS.Spacing.lg
                let total = geo.size.width - gap
                let leftW = total * 2.0 / 5.0
                let rightW = total * 3.0 / 5.0
                HStack(spacing: gap) {
                    recordControlCard
                        .frame(width: leftW)
                    waveformCard
                        .frame(width: rightW)
                }
            }
            .frame(height: 220)
            .padding(.horizontal, DS.Spacing.lg)

            // 底部：流式转写区域
            transcriptArea
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.bottom, DS.Spacing.md)
        }
        .background(DS.Surface.windowBg)
        .onAppear { recorder.refreshDevices() }
    }

    // MARK: - 录制控制

    private var recordControlCard: some View {
        VStack(spacing: DS.Spacing.sm) {
            // 计时器
            Text(recorder.formattedElapsed())
                .font(.system(size: 36, weight: .light, design: .monospaced))
                .foregroundColor(recorder.isRecording ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            // 状态
            Text(stateText)
                .font(.system(size: DS.Font.secondary))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // 控制按钮（按钮稍小，整体下移）
            HStack(spacing: DS.Spacing.md) {
                if recorder.isRecording {
                    // 暂停/恢复
                    Button(action: {
                        recorder.isPaused ? recorder.resumeRecording() : recorder.pauseRecording()
                    }) {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 56, height: 38)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(recorder.isPaused ? .green : .orange)

                    // 停止并转写
                    Button(action: stopAndTranscribe) {
                        Label("停止并转写", systemImage: "stop.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 140, minHeight: 38)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                } else {
                    // 开始录制
                    Button(action: startRecording) {
                        Label("开始录制", systemImage: "mic.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(minWidth: 150, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.red)
                    .disabled(!canStartRecording || asr.isTranscribing)
                }
            }
            .padding(.top, DS.Spacing.lg)

            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.Surface.controlBg)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .stroke(DS.Surface.separator, lineWidth: 0.5))
        )
    }

    // MARK: - 录制模式 Pill

    private var modeSelectorPill: some View {
        Button(action: { showModePicker = true }) {
            HStack(spacing: 6) {
                Image(systemName: recorder.recordingMode.iconName)
                    .foregroundStyle(.orange)
                    .font(.callout)
                Text(recorder.recordingMode.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: recorder.isRecording ? "lock.fill" : "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(DS.Surface.controlBg)
                    .overlay(Capsule().stroke(DS.Surface.separator, lineWidth: 0.5))
            )
            .contentShape(Capsule())
            .opacity(recorder.isRecording ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording)
        .help(recorder.isRecording ? "录制中无法切换，请先停止" : "点击切换录制模式")
        .popover(isPresented: $showModePicker, arrowEdge: .bottom) {
            modePickerPopover
        }
    }

    private var modePickerPopover: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(RecordingMode.allCases, id: \.self) { mode in
                Button(action: {
                    recorder.recordingMode = mode
                    showModePicker = false
                }) {
                    HStack(spacing: 10) {
                        Image(systemName: mode.iconName)
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.displayName)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(modeDescription(mode))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if recorder.recordingMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .font(.callout)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(recorder.recordingMode == mode ? Color.accentColor.opacity(0.08) : .clear)
                )
            }
        }
        .padding(8)
        .frame(width: 280)
    }

    private func modeDescription(_ mode: RecordingMode) -> String {
        switch mode {
        case .systemAudio: return "从声卡 / 虚拟设备捕获系统输出"
        case .microphone:  return "从麦克风录制人声"
        case .mix:         return "声卡 + 麦克风混录（后处理合并）"
        }
    }

    // MARK: - 音频源选择 Pill（设备）

    private var deviceSelectorPill: some View {
        Button(action: { showDevicePicker = true }) {
            HStack(spacing: 6) {
                Image(systemName: deviceIconName)
                    .foregroundStyle(.blue)
                    .font(.callout)
                Text(currentDeviceLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: recorder.isRecording ? "lock.fill" : "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(DS.Surface.controlBg)
                    .overlay(Capsule().stroke(DS.Surface.separator, lineWidth: 0.5))
            )
            .contentShape(Capsule())
            .opacity(recorder.isRecording ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording)
        .help(recorder.isRecording ? "录制中无法切换，请先停止" : "点击切换音频源设备")
        .popover(isPresented: $showDevicePicker, arrowEdge: .bottom) {
            devicePickerPopover
        }
    }

    private var deviceIconName: String {
        switch recorder.recordingMode {
        case .systemAudio: return "speaker.wave.2.fill"
        case .microphone:  return "mic.fill"
        case .mix:         return "person.wave.2.fill"
        }
    }

    private var currentDeviceLabel: String {
        switch recorder.recordingMode {
        case .systemAudio:
            return recorder.selectedSystemDevice?.displayName ?? "未选择"
        case .microphone:
            return recorder.selectedMicDevice?.displayName ?? "未选择"
        case .mix:
            let sys = recorder.selectedSystemDevice?.displayName ?? "?"
            let mic = recorder.selectedMicDevice?.displayName ?? "?"
            return "\(sys) + \(mic)"
        }
    }

    // MARK: - 波形

    private var waveformCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(waveformActive ? Color.orange : .secondary)
                Text("实时波形")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if recorder.isRecording && !recorder.isPaused {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .opacity(0.9)
                        Text("REC")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.red)
                    }
                } else if recorder.isPaused {
                    Text("已暂停")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            WaveformView(rmsHistory: $recorder.rmsHistory, isActive: waveformActive)

            // 音量条
            VolumeBar(level: recorder.isRecording && !recorder.isPaused ? recorder.rmsLevel : 0)
                .frame(height: 6)
                .padding(.top, DS.Spacing.xs)
        }
        .padding(DS.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(DS.Surface.controlBg)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg)
                    .stroke(DS.Surface.separator, lineWidth: 0.5))
        )
    }

    private var waveformActive: Bool {
        recorder.isRecording && !recorder.isPaused
    }

    // MARK: - 转写区域

    private var transcriptArea: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                if asr.isTranscribing {
                    ProgressView().scaleEffect(0.6)
                    Text("流式转写中…")
                        .font(.caption)
                        .foregroundStyle(DS.Status.transcribing)
                } else {
                    Text("转写预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !asr.partialText.isEmpty {
                    Text("\(asr.partialText.count) 字")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView {
                if asr.partialText.isEmpty {
                    Text("开始录制后可在此实时预览转写内容")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text(asr.partialText)
                        .font(.system(size: DS.Font.primary))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Spacing.md)
                }
            }
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md)
                    .fill(DS.Surface.textBg)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                        .stroke(DS.Surface.separator.opacity(0.3), lineWidth: 0.5))
            )
        }
        .frame(minHeight: 160)
    }

    // MARK: - 设备选择（popover，与模式 pill 交互一致）

    private var devicePickerPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部标题栏：标题 + 刷新按钮
            HStack {
                Text("音频源")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    recorder.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("刷新设备列表")
            }
            .padding(.horizontal, 2)

            // 系统音频区
            if recorder.recordingMode == .systemAudio || recorder.recordingMode == .mix {
                deviceSection(
                    title: "系统音频",
                    emptyHint: "未检测到环回设备（BlackHole 等）",
                    devices: recorder.availableSystemDevices,
                    isSelected: { recorder.selectedSystemDevice?.id == $0.id },
                    onSelect: { device in
                        recorder.selectedSystemDevice = device
                        if recorder.recordingMode != .mix { showDevicePicker = false }
                    }
                )
            }

            // 麦克风区
            if recorder.recordingMode == .microphone || recorder.recordingMode == .mix {
                deviceSection(
                    title: "麦克风",
                    emptyHint: "未检测到麦克风设备",
                    devices: recorder.availableMicDevices,
                    isSelected: { recorder.selectedMicDevice?.id == $0.id },
                    onSelect: { device in
                        recorder.selectedMicDevice = device
                        if recorder.recordingMode != .mix { showDevicePicker = false }
                    }
                )
            }
        }
        .padding(10)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func deviceSection(
        title: String,
        emptyHint: String,
        devices: [AudioCaptureEngine.AudioInputDevice],
        isSelected: @escaping (AudioCaptureEngine.AudioInputDevice) -> Bool,
        onSelect: @escaping (AudioCaptureEngine.AudioInputDevice) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            if devices.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DS.Surface.controlBg.opacity(0.5))
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        Button(action: { onSelect(device) }) {
                            HStack(spacing: 8) {
                                Text(device.displayName)
                                    .font(.callout)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if isSelected(device) {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.blue)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            isSelected(device)
                                ? Color.blue.opacity(0.08)
                                : Color.clear
                        )
                        if index < devices.count - 1 {
                            Divider().padding(.leading, 10)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DS.Surface.controlBg.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(DS.Surface.separator, lineWidth: 0.5)
                )
            }
        }
    }

    private var canStartRecording: Bool {
        switch recorder.recordingMode {
        case .systemAudio: return recorder.selectedSystemDevice != nil
        case .microphone:  return recorder.selectedMicDevice != nil
        case .mix:         return recorder.selectedSystemDevice != nil && recorder.selectedMicDevice != nil
        }
    }

    // MARK: - 动作

    private var stateText: String {
        if !recorder.isRecording { return "待机" }
        if recorder.isPaused { return "已暂停" }
        return "录制中"
    }

    private func startRecording() {
        recorder.startRecording()
        // 同时启动 C+ 延迟提交滑窗实时转写
        if let fileURL = recorder.recordingFileURL {
            asr.startPartialTranscription(
                audioURL: fileURL,
                framesProvider: { AudioCaptureEngine.shared.capturedFrames },
                sampleRateProvider: { AudioCaptureEngine.shared.captureSampleRate }
            )
        }
        Logger.recording.info("用户触发开始录制")
    }

    private func stopAndTranscribe() {
        asr.stopPartialTranscription()
        recorder.stopRecording()
        if let fileURL = recorder.recordingFileURL {
            Logger.recording.info("用户触发停止并转写", metadata: ["file": fileURL.lastPathComponent])
            scheduler.enqueueRecording(fileURL: fileURL)
        }
    }
}

// MARK: - 音量条

struct VolumeBar: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(colors: [
                        .green, .yellow, .red
                    ], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                    .animation(.easeOut(duration: 0.05), value: level)
            }
        }
    }
}
