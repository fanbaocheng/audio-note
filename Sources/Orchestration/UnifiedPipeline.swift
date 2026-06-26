import Foundation

/// 统一处理流水线 — 编排 4 阶段处理流程
/// Stage 0: 输入适配（由 InputAdapter 处理，选择哪个引擎）
/// Stage 1: 音频标准化（ffmpeg → 16kHz mono wav）
/// Stage 2: 预处理（VAD / 去噪）
/// Stage 3: ASR 转写
/// Stage 4: 结果输出
@MainActor
final class UnifiedPipeline: ObservableObject {
    static let shared = UnifiedPipeline()
    private init() {}

    /// 处理 URL 下载 → 自动转写
    func processDownload(task: UniTask, outputDir: URL? = nil) async {
        Logger.pipeline.info("Pipeline 开始: URL 下载", metadata: ["url": task.sourceURL ?? "nil", "id": task.id.uuidString.prefix(8)])

        // Stage 0: 下载
        do {
            let audioURL = try await DownloadEngine.shared.execute(task: task)
            Logger.pipeline.info("下载完成, 输出: \(audioURL.lastPathComponent)")

            // 自动转写?
            guard task.autoTranscribe else {
                Logger.pipeline.info("跳过转写 (autoTranscribe=false)")
                task.status = .skippedTranscribe(audioURL)
                return
            }

            // Stage 1-3: 标准化 + ASR
            try await transcribeAudio(url: audioURL, task: task, outputDir: outputDir)
        } catch let err as EngineError {
            Logger.pipeline.error("Pipeline 下载失败", error: err)
            task.status = .failed(err.localizedDescription)
        } catch {
            Logger.pipeline.error("Pipeline 未知错误", error: error)
            task.status = .failed(error.localizedDescription)
        }
        TaskScheduler.shared.persist()
    }

    /// 处理录制完毕 → 自动转写
    /// 注：task 由 Scheduler 创建并入队，这里复用同一对象（保证 UI 绑定生效）
    func processRecording(task: UniTask, fileURL: URL, outputDir: URL? = nil) async {
        task.status = .downloaded(fileURL)
        task.outputFileURL = fileURL

        Logger.pipeline.info("Pipeline 开始: 录制转写", metadata: ["file": fileURL.lastPathComponent, "id": task.id.uuidString.prefix(8)])

        do {
            try await transcribeAudio(url: fileURL, task: task, outputDir: outputDir)
        } catch {
            Logger.pipeline.error("录制转写失败", error: error)
            task.status = .failed(error.localizedDescription)
        }
        TaskScheduler.shared.persist()
    }

    /// 处理本地文件导入 → 转写
    /// 注：task 由 Scheduler 创建并入队，这里复用同一对象
    func processFileImport(task: UniTask, fileURL: URL, outputDir: URL? = nil) async {
        Logger.pipeline.info("Pipeline 开始: 文件导入", metadata: ["file": fileURL.lastPathComponent, "id": task.id.uuidString.prefix(8)])

        // 视频文件需要先抽音轨
        let audioExtensions = ["wav", "mp3", "m4a", "aac", "flac", "ogg", "opus", "aiff"]
        let ext = fileURL.pathExtension.lowercased()

        let audioURL: URL
        if audioExtensions.contains(ext) {
            audioURL = fileURL
        } else {
            // 视频 → 抽音轨
            task.status = .extracting
            do {
                audioURL = try await AudioProcessingEngine.shared.extractAudio(from: fileURL)
                Logger.pipeline.info("音频抽取完成", metadata: ["audio": audioURL.lastPathComponent])
            } catch {
                Logger.pipeline.error("音频抽取失败", error: error)
                task.status = .failed("音频抽取失败: \(error.localizedDescription)")
                TaskScheduler.shared.persist()
                return
            }
        }

        task.status = .downloaded(audioURL)
        task.outputFileURL = audioURL

        do {
            try await transcribeAudio(url: audioURL, task: task, outputDir: outputDir)
        } catch {
            Logger.pipeline.error("文件导入转写失败", error: error)
            task.status = .failed(error.localizedDescription)
        }
        TaskScheduler.shared.persist()
    }

    // MARK: - Private: 核心转写流程

    private func transcribeAudio(url audioURL: URL, task: UniTask, outputDir: URL?) async throws {
        // Stage 1: 确保音频是 16kHz mono wav
        task.status = .extracting
        var normalizedURL = audioURL

        // 检查是否需要标准化（非 .wav 或采样率不对）
        if audioURL.pathExtension.lowercased() != "wav" {
            Logger.pipeline.info("Stage 1: 音频标准化")
            normalizedURL = try await AudioProcessingEngine.shared.resample(input: audioURL)
        }

        // Stage 2: （VAD 可选，此处保证文件为标准化 wav）

        // Stage 3: ASR
        task.status = .transcribing
        let asrStart = Date()
        task.startedAt = task.startedAt ?? asrStart
        task.transcribeStartedAt = asrStart
        Logger.pipeline.info("Stage 3: 开始 ASR 转写")

        let outDir = outputDir ?? normalizedURL.deletingLastPathComponent()
        let result = try await ASRService.shared.transcribeBatch(
            audioURL: normalizedURL,
            title: task.title,
            outputDir: outDir,
            task: task
        )

        // Stage 4: 结果输出
        task.transcriptURL = result.txtURL
        task.transcriptSRTURL = result.srtURL
        task.transcriptCharCount = result.text.count
        task.status = .completed(normalizedURL)
        let done = Date()
        task.transcribeFinishedAt = done
        task.finishedAt = done

        Logger.pipeline.info("Pipeline 完成", metadata: [
            "chars": result.text.count,
            "txt": result.txtURL.lastPathComponent
        ])
    }
}

