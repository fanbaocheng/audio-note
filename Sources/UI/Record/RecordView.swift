import SwiftUI

/// 录制中心 — 声卡环回录制控制 + 实时波形 + 流式转写预览
struct RecordView: View {
    @EnvironmentObject var recorder: AudioCaptureEngine
    @EnvironmentObject var asr: ASRService
    @EnvironmentObject var scheduler: TaskScheduler
    @State private var showDevicePicker: Bool = false

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            // 顶部：设备选择 + 静音设置
            HStack(spacing: DS.Spacing.md) {
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
        .sheet(isPresented: $showDevicePicker) {
            devicePickerSheet
        }
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
                    .disabled(recorder.selectedDevice == nil || asr.isTranscribing)
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

    // MARK: - 音频源选择 Pill

    private var deviceSelectorPill: some View {
        Button(action: { showDevicePicker = true }) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.blue)
                    .font(.callout)
                Text("音频源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(recorder.selectedDevice?.displayName ?? "未选择")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
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
        }
        .buttonStyle(.plain)
        .help("点击切换音频源")
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

    // MARK: - 设备选择

    private var devicePickerSheet: some View {
        VStack(spacing: DS.Spacing.lg) {
            Text("选择音频源").font(.headline)

            List(recorder.availableDevices) { device in
                Button(action: {
                    recorder.selectedDevice = device
                    showDevicePicker = false
                }) {
                    HStack {
                        Text(device.displayName)
                        Spacer()
                        if recorder.selectedDevice?.id == device.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button("刷新设备") { recorder.refreshDevices() }
                Spacer()
                Button("关闭") { showDevicePicker = false }
            }
            .padding()
        }
        .frame(width: 400, height: 300)
        .padding()
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
