import XCTest
@testable import AudioNote

@MainActor
final class AudioNoteTests: XCTestCase {

    func testUniTaskCreation() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/video.mp4")
        XCTAssertEqual(task.inputType, .urlDownload)
        XCTAssertEqual(task.sourceURL, "https://example.com/video.mp4")
        XCTAssertEqual(task.status.displayText, "等待中")
        XCTAssertTrue(task.autoTranscribe)
    }

    func testUniTaskRecording() {
        let task = UniTask(inputType: .recording, sourceFilePath: "/tmp/test.wav")
        XCTAssertEqual(task.inputType, .recording)
    }

    func testTaskStatusTransitions() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test.mp3")
        task.status = .downloading
        XCTAssertTrue(task.status.isRunning)
        task.status = .completed(URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertTrue(task.status.isTerminal)
    }

    func testFormatElapsed() {
        XCTAssertEqual(UniTask.formatElapsed(30), "30s")
        XCTAssertEqual(UniTask.formatElapsed(90), "01:30")
        XCTAssertEqual(UniTask.formatElapsed(3661), "1:01:01")
    }

    func testDisplayTitleFallback() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test.mp3")
        XCTAssertEqual(task.displayTitle, "https://example.com/test.mp3")
        task.title = "My Video"
        XCTAssertEqual(task.displayTitle, "My Video")
    }

    func testTaskSnapshotRoundTrip() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test.mp3")
        task.title = "Test"
        task.status = .completed(URL(fileURLWithPath: "/tmp/test.wav"))
        let snap = task.snapshot()
        XCTAssertEqual(snap.title, "Test")
        let restored = UniTask(inputType: snap.inputType, sourceURL: snap.sourceURL)
        restored.restore(from: snap)
        if case .completed = restored.status { } else { XCTFail("Expected completed") }
    }

    func testTaskPriorityBounds() {
        let scheduler = TaskScheduler()
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test.mp3")
        scheduler.setPriority(task, priority: 20)
        XCTAssertEqual(task.priority, 10)
        scheduler.setPriority(task, priority: -5)
        XCTAssertEqual(task.priority, 0)
    }

    func testLoggerModuleNames() {
        XCTAssertEqual(Logger.download.name, "DOWNLOAD")
        XCTAssertEqual(Logger.asr.name, "ASR")
    }

    func testBinaryResolverDiagnostic() {
        XCTAssertTrue(BinaryResolver.diagnostic().contains("yt-dlp"))
    }

    func testEngineErrorDescriptions() {
        XCTAssertEqual(EngineError.binaryMissing("ffmpeg").errorDescription, "缺少依赖: ffmpeg")
        XCTAssertEqual(EngineError.downloadFailed("timeout").errorDescription, "下载失败: timeout")
    }

    func testConcurrentTaskUUIDs() {
        let ids = Set((0..<50).map { _ in UniTask(inputType: .urlDownload, sourceURL: "x").id })
        XCTAssertEqual(ids.count, 50)
    }
}
