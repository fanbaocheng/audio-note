import Foundation
import Combine

/// ASR 转写服务
///
/// 完整迁移自 AudioTranscriber.Transcriber，包含「C+ 延迟提交滑窗」实时转写策略。
///
/// 提供两类调用：
/// - `transcribeBatch(audioURL:title:outputDir:task:)`：离线全量转写（用于下载完/录制后），
///   走 `transcribe.py <audio> <title>`，从 JSON line 拿到完整文本，自己写 .txt。
/// - `startPartialTranscription(audioURL:framesProvider:sampleRateProvider:) / stopPartialTranscription()`：
///   录制中边录边转。基于 C+ 滑窗反复调 `transcribe.py --start-frame X --end-frame Y` 拿窗口文本，
///   配合 overlap 对齐去重 + stableLag 缓冲期 commit + 打字机自适应 interval 输出。
///
/// 实时流式策略（方案 C+ 延迟提交）：
/// ```
/// 时间轴:  [────── COMMITTED ──────│──── TENTATIVE ────│── HOT ──]
///         0                       T-stableLag         T-hot     now
///                                 ↑                   ↑
///                                 已 committed 永不变  正在 ASR 重转中
///
/// 每 pollIntervalSec 一次:
///   1. windowEnd = now (帧数)
///   2. windowStart = max(0, committedEndFrame - overlapFrames)
///   3. 若 (windowEnd - committedEndFrame) < minWindowSec → skip
///   4. 调 transcribe.py --start-frame=windowStart --end-frame=windowEnd 拿到 windowText
///   5. windowText 对齐 committedText 末尾（用 overlap 区找锚点）→ 拆成 [olderPart, hotPart]
///        olderPart 对应音频 < windowEnd - stableLagFrames → 追加到 committedText
///        hotPart   对应音频 >= windowEnd - stableLagFrames → 显示在 tentativeText（每轮替换）
///   6. UI: partialText = committedText + tentativeText
/// ```
@MainActor
public final class ASRService: ObservableObject {
    public static let shared = ASRService()
    private init() {}

    // MARK: - 兼容字段（保留 UI 旧绑定）

    @Published public var isTranscribing: Bool = false
    @Published public var progress: Double = 0
    @Published public var fullTranscript: String = ""
    @Published public var error: String?
    @Published public var elapsedSec: TimeInterval = 0
    @Published public var etaSec: TimeInterval?

    /// 实时流式总文本（committed + tentative，UI 绑定这个）
    @Published public var partialText: String = ""
    /// 实时流式正在运行
    @Published public var isStreaming = false

    // MARK: - C+ 流式参数

    private let pollIntervalSec: Double = 3.0
    private let initialDelaySec: Double = 5.0
    private let minWindowSec: Double = 3.5
    private let overlapSec: Double = 1.0
    private let stableLagSec: Double = 5.0
    private let maxWindowSec: Double = 25.0

    // MARK: - 流式状态

    private var committedText: String = ""
    private var tentativeText: String = ""
    private var committedEndFrame: UInt64 = 0
    private var lastWindowEndFrame: UInt64 = 0

    private var framesProvider: (@MainActor () -> UInt64)?
    private var sampleRateProvider: (@MainActor () -> Double)?

    // 打字机
    private var pendingCommitChars: [Character] = []
    private var typeTimer: Timer?
    private var currentTypeInterval: TimeInterval = 0.05
    private let perSegmentBudgetSec: TimeInterval = 2.8

    private var partialAudioURL: URL?
    private var partialTask: Task<Void, Never>?
    private var pollTimer: Timer?

    // MARK: - 计时器（离线转写 ETA）

    private var transcribeStartedAt: Date?
    private var elapsedTimer: Timer?

    // MARK: - 离线完整转写（UnifiedPipeline 调用入口）

    /// 批量转写音频文件
    /// - 返回：（全文文本，写入的 .txt URL，预留 .srt URL）
    /// - 注：transcribe.py 当前只产文本，不生成 SRT；返回的 srtURL 用作占位（与 txt 同目录 .srt 后缀）
    ///
    /// 断点续转：在 outputDir 下放 `<basename>.partial.tsv` 作为 sidecar，
    /// 转写过程中每段完成立即追加「index\ttext\n」。下次调用 transcribeBatch 时检测此文件，
    /// 取最大 index+1 作为 resume-from-segment 传给 transcribe.py 跳过前面已完成段。
    public func transcribeBatch(
        audioURL: URL,
        title: String,
        outputDir: URL? = nil,
        task: UniTask? = nil
    ) async throws -> (text: String, txtURL: URL, srtURL: URL) {
        guard !isTranscribing else {
            throw EngineError.transcribeFailed("已有转写在运行中")
        }

        Logger.asr.info("开始批量转写", metadata: ["audio": audioURL.lastPathComponent, "title": title])

        isTranscribing = true
        progress = 0
        error = nil
        fullTranscript = ""
        startElapsedTimer()

        // 非 wav 文件 → ffmpeg 转为 16k mono PCM wav
        var workingURL = audioURL
        var tempConvertedURL: URL?
        let ext = audioURL.pathExtension.lowercased()
        if ext != "wav" {
            Logger.asr.info("非 wav 文件，启动 ffmpeg 预处理", metadata: ["ext": ext])
            do {
                let converted = try await convertToWav(audioURL)
                workingURL = converted
                tempConvertedURL = converted
            } catch {
                isTranscribing = false
                stopElapsedTimer()
                Logger.asr.error("音视频转码失败", error: error)
                throw EngineError.transcribeFailed("音视频转码失败：\(error.localizedDescription)")
            }
        }

        // 准备 sidecar 路径（基于最终输出目录 + 原音频 basename）
        let outDir = outputDir ?? audioURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let txtURL = outDir.appendingPathComponent("\(baseName).txt")
        let srtURL = outDir.appendingPathComponent("\(baseName).srt")
        let partialURL = outDir.appendingPathComponent("\(baseName).partial.tsv")
        task?.transcribePartialURL = partialURL

        // 读 sidecar，确定从哪一段断点续转
        let (priorText, resumeFromSegment) = readPartialSidecar(partialURL)
        if resumeFromSegment > 0 {
            Logger.asr.info("断点续转", metadata: [
                "sidecar": partialURL.lastPathComponent,
                "resumeFromSegment": resumeFromSegment,
                "priorChars": priorText.count
            ])
            task?.transcribeCompletedSegments = resumeFromSegment
        }

        // 调 transcribe.py 拿新增文本（仅 resume 之后的段）
        let newText = await runFullTranscription(
            audioURL: workingURL,
            title: title,
            partialFile: partialURL,
            resumeFromSegment: resumeFromSegment,
            task: task
        )

        // 合并：sidecar 已有文本 + 本次新转写文本
        var resultText = newText
        if !priorText.isEmpty {
            resultText = priorText + (newText.isEmpty ? "" : "\n" + newText)
        }
        // 如果脚本没返回 newText（断点续转时全部段都跳过了），fall back 用 sidecar 完整内容
        if resultText.isEmpty && !priorText.isEmpty {
            resultText = priorText
        }

        progress = 1.0
        isTranscribing = false
        stopElapsedTimer()

        // 清理临时 wav
        if let tmp = tempConvertedURL {
            try? FileManager.default.removeItem(at: tmp)
        }

        guard !resultText.isEmpty else {
            Logger.asr.warn("转写结果为空", metadata: ["audio": audioURL.lastPathComponent])
            throw EngineError.transcribeFailed("转写无文本输出，可能音频为空/模型未加载/Python 依赖缺失")
        }

        do {
            try resultText.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.asr.error("写入 .txt 失败", error: error)
            throw EngineError.transcribeFailed("写入文本失败: \(error.localizedDescription)")
        }

        // 完整 .txt 已写入 → 可以清理 sidecar
        try? FileManager.default.removeItem(at: partialURL)

        fullTranscript = resultText
        task?.progress = 1.0
        task?.transcriptCharCount = resultText.count

        Logger.asr.info("转写完成", metadata: [
            "chars": resultText.count,
            "txt": txtURL.path
        ])

        return (resultText, txtURL, srtURL)
    }

    // MARK: - 断点续转 sidecar

    /// 读取 `.partial.tsv` sidecar，返回（已完成段拼成的文本，下一段索引）
    /// sidecar 格式：每行 `index\ttext\n`（text 可能为空字符串表示静音段）
    private func readPartialSidecar(_ url: URL) -> (text: String, nextSegment: Int) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8), !raw.isEmpty else {
            return ("", 0)
        }
        var maxIdx = -1
        var nonEmptyTexts: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let idxStr = line[..<tab]
            let text = line[line.index(after: tab)...]
            if let idx = Int(idxStr) {
                if idx > maxIdx { maxIdx = idx }
                if !text.isEmpty { nonEmptyTexts.append(String(text)) }
            }
        }
        if maxIdx < 0 { return ("", 0) }
        return (nonEmptyTexts.joined(separator: "\n"), maxIdx + 1)
    }

    // MARK: - 实时部分转写（C+ 延迟提交滑窗）

    /// 启动实时流式转写。
    /// - Parameter audioURL: 正在录制的 wav 文件（边写边读）
    /// - Parameter framesProvider: 实时读"已采集 frame 数"（从 AudioCaptureEngine.capturedFrames）
    /// - Parameter sampleRateProvider: 实时读"采集采样率"（从 AudioCaptureEngine.captureSampleRate）
    public func startPartialTranscription(
        audioURL: URL,
        framesProvider: (@MainActor () -> UInt64)? = nil,
        sampleRateProvider: (@MainActor () -> Double)? = nil
    ) {
        guard !isStreaming else { return }
        Logger.asr.info("启动实时滑窗转写", metadata: ["audio": audioURL.lastPathComponent])
        isStreaming = true
        partialText = ""
        committedText = ""
        tentativeText = ""
        committedEndFrame = 0
        lastWindowEndFrame = 0
        pendingCommitChars.removeAll()
        partialAudioURL = audioURL
        self.framesProvider = framesProvider
        self.sampleRateProvider = sampleRateProvider
        error = nil

        startTypewriter()
        schedulePollTimer()
    }

    /// 停止实时转写。flush 所有未输出字符 + tentative → committed。
    public func stopPartialTranscription() {
        guard isStreaming else { return }
        Logger.asr.info("停止实时滑窗转写")
        partialTask?.cancel()
        partialTask = nil
        pollTimer?.invalidate()
        pollTimer = nil
        isStreaming = false

        if !pendingCommitChars.isEmpty {
            committedText.append(String(pendingCommitChars))
            pendingCommitChars.removeAll()
        }
        if !tentativeText.isEmpty {
            committedText += tentativeText
            tentativeText = ""
        }
        partialText = committedText
        stopTypewriter()

        if !partialText.isEmpty {
            fullTranscript = partialText
        }

        framesProvider = nil
        sampleRateProvider = nil
        partialAudioURL = nil
    }

    // MARK: - 计时器

    private func startElapsedTimer() {
        stopElapsedTimer()
        transcribeStartedAt = Date()
        elapsedSec = 0
        etaSec = nil
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        transcribeStartedAt = nil
        etaSec = nil
    }

    private func tickElapsed() {
        guard let start = transcribeStartedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        elapsedSec = elapsed
        if progress >= 0.03 && progress < 1.0 {
            let remaining = elapsed * (1.0 - progress) / progress
            etaSec = max(1, remaining)
        } else {
            etaSec = nil
        }
    }

    // MARK: - ffmpeg 转码

    private func convertToWav(_ src: URL) async throws -> URL {
        guard let ffmpegURL = BinaryResolver.ffmpegURL() else {
            throw EngineError.binaryMissing("ffmpeg 未找到")
        }
        let tmpDir = FileManager.default.temporaryDirectory
        let dstURL = tmpDir.appendingPathComponent("transcribe_\(UUID().uuidString).wav")

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = ffmpegURL
                proc.arguments = [
                    "-y", "-i", src.path,
                    "-vn",                  // 丢视频流
                    "-ac", "1",             // mono
                    "-ar", "16000",         // 16kHz
                    "-c:a", "pcm_s16le",    // 16-bit PCM
                    dstURL.path
                ]
                let errPipe = Pipe()
                proc.standardError = errPipe
                proc.standardOutput = Pipe()
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0,
                       FileManager.default.fileExists(atPath: dstURL.path) {
                        cont.resume(returning: dstURL)
                    } else {
                        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8) ?? "ffmpeg 退出码 \(proc.terminationStatus)"
                        cont.resume(throwing: NSError(domain: "ASRService", code: Int(proc.terminationStatus), userInfo: [
                            NSLocalizedDescriptionKey: errStr.split(separator: "\n").suffix(3).joined(separator: "\n")
                        ]))
                    }
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 滑窗调度

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: initialDelaySec, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.runOnePoll()
                self?.startRepeatingPolls()
            }
        }
    }

    private func startRepeatingPolls() {
        guard isStreaming else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollIntervalSec, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runOnePoll() }
        }
    }

    private func runOnePoll() {
        guard isStreaming, partialTask == nil else { return }
        guard let url = partialAudioURL else { return }
        guard let sr = sampleRateProvider?(), sr > 0 else { return }
        guard let nowFrame = framesProvider?(), nowFrame > 0 else { return }

        let newAudioFrames = nowFrame > committedEndFrame ? nowFrame - committedEndFrame : 0
        let newAudioSec = Double(newAudioFrames) / sr
        if newAudioSec < minWindowSec { return }
        if nowFrame == lastWindowEndFrame { return }

        let overlapFrames = UInt64(overlapSec * sr)
        let maxFrames = UInt64(maxWindowSec * sr)
        var windowStart = committedEndFrame > overlapFrames ? committedEndFrame - overlapFrames : 0
        let windowEnd = nowFrame
        if windowEnd - windowStart > maxFrames {
            windowStart = windowEnd - maxFrames
        }
        lastWindowEndFrame = windowEnd

        let snapshotCommittedFrame = committedEndFrame
        partialTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let text = await self.runWindowTranscription(
                audioURL: url,
                startFrame: windowStart,
                endFrame: windowEnd
            )
            self.partialTask = nil
            if !self.isStreaming { return }
            if text.isEmpty { return }
            self.ingestWindow(
                text: text,
                windowStart: windowStart,
                windowEnd: windowEnd,
                sampleRate: sr,
                snapshotCommittedFrame: snapshotCommittedFrame
            )
        }
    }

    private func ingestWindow(
        text: String,
        windowStart: UInt64,
        windowEnd: UInt64,
        sampleRate: Double,
        snapshotCommittedFrame: UInt64
    ) {
        let windowText = text
        let stableLagFrames = UInt64(stableLagSec * sampleRate)

        let overlapDurFrames = snapshotCommittedFrame > windowStart
            ? snapshotCommittedFrame - windowStart
            : 0
        let overlapDurSec = Double(overlapDurFrames) / sampleRate

        let approxOverlapChars = max(0, Int(overlapDurSec * 5.0))
        let committedTail = String(committedText.suffix(min(committedText.count, max(approxOverlapChars * 2, 30))))

        let alignedNewPart = alignAndCut(committedTail: committedTail, windowText: windowText)

        let commitBoundaryFrame: UInt64 = windowEnd > stableLagFrames
            ? windowEnd - stableLagFrames
            : 0

        let coveredStartFrame = snapshotCommittedFrame
        let coveredEndFrame = windowEnd
        let coveredFrames = coveredEndFrame > coveredStartFrame
            ? coveredEndFrame - coveredStartFrame : 0

        let alignedChars = Array(alignedNewPart)
        let totalChars = alignedChars.count
        if totalChars == 0 {
            tentativeText = ""
            recomputePartial()
            return
        }

        let commitRatio: Double
        if commitBoundaryFrame <= coveredStartFrame {
            commitRatio = 0
        } else if commitBoundaryFrame >= coveredEndFrame {
            commitRatio = 1
        } else if coveredFrames == 0 {
            commitRatio = 1
        } else {
            commitRatio = Double(commitBoundaryFrame - coveredStartFrame) / Double(coveredFrames)
        }
        let commitCharCount = max(0, min(totalChars, Int(Double(totalChars) * commitRatio)))

        var actualCommitCount = commitCharCount
        let punctSet: Set<Character> = ["，", "。", "！", "？", "、", ";", "；", ":", "：", ".", ",", "!", "?"]
        let lookahead = min(10, totalChars - commitCharCount)
        for offset in 0..<lookahead {
            let idx = commitCharCount + offset
            if idx < totalChars && punctSet.contains(alignedChars[idx]) {
                actualCommitCount = idx + 1
                break
            }
        }
        if commitRatio >= 0.95 { actualCommitCount = totalChars }

        let newCommit = String(alignedChars[0..<actualCommitCount])
        let newTentative = actualCommitCount < totalChars
            ? String(alignedChars[actualCommitCount..<totalChars])
            : ""

        if !newCommit.isEmpty {
            pendingCommitChars.append(contentsOf: newCommit)
            let qLen = max(1, pendingCommitChars.count)
            var interval = perSegmentBudgetSec / Double(qLen)
            if interval < 0.02 { interval = 0.02 }
            if interval > 0.10 { interval = 0.10 }
            currentTypeInterval = interval
            restartTypewriter()
        }

        if totalChars > 0, actualCommitCount > 0 {
            let advanceFrames = UInt64(
                Double(coveredFrames) * Double(actualCommitCount) / Double(totalChars)
            )
            committedEndFrame = coveredStartFrame + advanceFrames
        }

        tentativeText = newTentative
        recomputePartial()
    }

    private static let punctNormSet: Set<Character> = {
        var s = Set<Character>()
        let p = #"，。！？、；：,.!?;:"'""''（）()【】[]《》<>—…·　 "# + "\t\n\r"
        for c in p { s.insert(c) }
        return s
    }()

    private func normalize(_ s: String) -> (clean: [Character], origIdx: [Int]) {
        var clean: [Character] = []
        var origIdx: [Int] = []
        for (i, c) in s.enumerated() {
            if !Self.punctNormSet.contains(c) {
                clean.append(c)
                origIdx.append(i)
            }
        }
        return (clean, origIdx)
    }

    private func alignAndCut(committedTail: String, windowText: String) -> String {
        if committedTail.isEmpty { return windowText }
        if windowText.isEmpty { return "" }

        let s = normalize(committedTail).clean
        let (n, nIdx) = normalize(windowText)
        if s.isEmpty || n.isEmpty { return windowText }

        let nChars = Array(windowText)
        let maxK = min(60, s.count, n.count)
        let minK = 3

        if maxK >= minK {
            for k in stride(from: maxK, through: minK, by: -1) {
                let tail = Array(s.suffix(k))
                if n.count < k { continue }
                var bestPos = -1
                for i in stride(from: n.count - k, through: 0, by: -1) {
                    var ok = true
                    for j in 0..<k where n[i + j] != tail[j] { ok = false; break }
                    if ok { bestPos = i; break }
                }
                if bestPos >= 0 {
                    let lastNewFullIdx = nIdx[bestPos + k - 1]
                    var cutStart = lastNewFullIdx + 1
                    while cutStart < nChars.count && Self.punctNormSet.contains(nChars[cutStart]) {
                        cutStart += 1
                    }
                    if cutStart >= nChars.count { return "" }
                    return String(nChars[cutStart..<nChars.count])
                }
            }
        }

        var startIdx = 0
        while startIdx < nChars.count && Self.punctNormSet.contains(nChars[startIdx]) {
            startIdx += 1
        }
        return startIdx >= nChars.count ? "" : String(nChars[startIdx..<nChars.count])
    }

    private func recomputePartial() {
        partialText = committedText + tentativeText
    }

    // MARK: - 打字机

    private func startTypewriter() {
        stopTypewriter()
        typeTimer = Timer.scheduledTimer(withTimeInterval: currentTypeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.typeTick() }
        }
    }

    private func restartTypewriter() {
        stopTypewriter()
        typeTimer = Timer.scheduledTimer(withTimeInterval: currentTypeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.typeTick() }
        }
    }

    private func stopTypewriter() {
        typeTimer?.invalidate()
        typeTimer = nil
    }

    private func typeTick() {
        guard !pendingCommitChars.isEmpty else { return }
        let c = pendingCommitChars.removeFirst()
        committedText.append(c)
        recomputePartial()
    }

    // MARK: - 子进程调用 transcribe.py

    private func runFullTranscription(
        audioURL: URL,
        title: String,
        partialFile: URL? = nil,
        resumeFromSegment: Int = 0,
        task: UniTask? = nil
    ) async -> String {
        guard let script = BinaryResolver.transcribePyURL() else {
            Logger.asr.error("transcribe.py 未找到")
            return ""
        }
        var args = [script.path, audioURL.path, title]
        if let pf = partialFile {
            args.append(contentsOf: ["--partial-file", pf.path])
        }
        if resumeFromSegment > 0 {
            args.append(contentsOf: ["--resume-from-segment", "\(resumeFromSegment)"])
        }
        return await runProcess(args: args, updateProgress: true, task: task)
    }

    private func runWindowTranscription(
        audioURL: URL,
        startFrame: UInt64,
        endFrame: UInt64
    ) async -> String {
        guard let script = BinaryResolver.transcribePyURL() else {
            Logger.asr.error("transcribe.py 未找到（滑窗）")
            return ""
        }
        Logger.asr.info("滑窗 poll", metadata: [
            "startFrame": startFrame,
            "endFrame": endFrame,
            "frames": endFrame - startFrame
        ])
        let args = [
            script.path,
            audioURL.path,
            "",
            "--start-frame", "\(startFrame)",
            "--end-frame", "\(endFrame)",
        ]
        let text = await runProcess(args: args, updateProgress: false, task: nil)
        Logger.asr.info("滑窗 poll 完成", metadata: ["chars": text.count])
        return text
    }

    /// 启动 python3 transcribe.py 子进程。
    /// - 如果传入 task，则把 process 注册到 task.process，让 scheduler.cancel/pause 能 terminate。
    /// - 解析 JSON line `type=segment` 实时更新 task.transcribeCompletedSegments。
    private func runProcess(args: [String], updateProgress: Bool = true, task: UniTask? = nil) async -> String {
        guard let python3 = BinaryResolver.python3URL() else {
            Logger.asr.error("python3 未找到")
            return ""
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let process = Process()
            process.executableURL = python3
            process.arguments = args
            process.environment = ProcessInfo.processInfo.environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                // 注册到 task.process（必须在 MainActor 上），让 cancel/pause 能 terminate
                if let t = task {
                    Task { @MainActor in t.process = process }
                }
                let handle = stdoutPipe.fileHandleForReading

                Task {
                    var resultText = ""
                    do {
                        for try await line in handle.bytes.lines {
                            guard let data = line.data(using: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                            else { continue }

                            switch json["type"] as? String ?? "" {
                            case "progress":
                                if updateProgress {
                                    let pct = json["value"] as? Double ?? 0
                                    await MainActor.run {
                                        self.progress = pct / 100.0
                                        task?.progress = pct / 100.0
                                    }
                                }
                            case "segment":
                                if let idx = json["index"] as? Int {
                                    await MainActor.run {
                                        task?.transcribeCompletedSegments = idx + 1
                                    }
                                }
                            case "result":
                                resultText = json["text"] as? String ?? ""
                            case "error":
                                if updateProgress {
                                    let msg = json["message"] as? String
                                    await MainActor.run { self.error = msg }
                                }
                            default: break
                            }
                        }
                    } catch {}

                    process.waitUntilExit()

                    if process.terminationStatus != 0, resultText.isEmpty {
                        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let errStr = String(data: errData, encoding: .utf8) ?? ""
                        Logger.asr.warn("transcribe.py 非零退出: \(String(errStr.prefix(200)))")
                    }

                    if let t = task {
                        Task { @MainActor in
                            if t.process === process { t.process = nil }
                        }
                    }
                    continuation.resume(returning: resultText)
                }
            } catch {
                Logger.asr.error("transcribe.py 启动失败", error: error)
                continuation.resume(returning: "")
            }
        }
    }
}
