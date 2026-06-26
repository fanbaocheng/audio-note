import XCTest
@testable import AudioNote

@MainActor
final class AudioNoteFunctionalTests: XCTestCase {
    var scheduler: TaskScheduler!

    override func setUp() {
        super.setUp()
        scheduler = TaskScheduler()
        scheduler.allTasks.removeAll()
        scheduler.clearCompleted()
    }

    override func tearDown() {
        scheduler = nil
        super.tearDown()
    }

    func testFullTaskLifecycle() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test.mp3")
        scheduler.enqueue(task)
        XCTAssertEqual(scheduler.allTasks.count, 1)

        task.status = .downloading; task.progress = 0.5; task.speed = "2.1MiB/s"
        XCTAssertEqual(task.progress, 0.5)

        task.status = .completed(URL(fileURLWithPath: "/tmp/test.wav"))
        XCTAssertTrue(task.status.isTerminal)
    }

    func testCancelAndSkipTranscribe() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test.mp3")
        scheduler.enqueue(task)
        task.status = .downloading
        scheduler.cancel(task)
        if case .cancelled = task.status { } else { XCTFail() }

        let task2 = UniTask(inputType: .urlDownload, sourceURL: "https://example.com/test2.mp3")
        task2.status = .downloaded(URL(fileURLWithPath: "/tmp/test.wav"))
        scheduler.enqueue(task2)
        scheduler.skipTranscribe(task2)
        if case .skippedTranscribe = task2.status { } else { XCTFail() }
    }

    func testTaskFiltering() {
        let t1 = UniTask(inputType: .urlDownload, sourceURL: "https://a.com")
        t1.status = .downloading
        let t2 = UniTask(inputType: .urlDownload, sourceURL: "https://b.com")
        t2.status = .transcribing
        let t3 = UniTask(inputType: .urlDownload, sourceURL: "https://c.com")
        t3.status = .completed(URL(fileURLWithPath: "/tmp/c.wav"))
        let t4 = UniTask(inputType: .urlDownload, sourceURL: "https://d.com")
        t4.status = .failed("e")

        [t1, t2, t3, t4].forEach { scheduler.enqueue($0) }
        XCTAssertEqual(scheduler.downloadingTasks.count, 1)
        XCTAssertEqual(scheduler.transcribingTasks.count, 1)
        XCTAssertEqual(scheduler.completedTasks.count, 1)
        XCTAssertEqual(scheduler.failedTasks.count, 1)
    }

    func testClearCompleted() {
        let t1 = UniTask(inputType: .urlDownload, sourceURL: "https://a.com")
        t1.status = .completed(URL(fileURLWithPath: "/tmp/a.wav"))
        let t2 = UniTask(inputType: .urlDownload, sourceURL: "https://b.com")
        t2.status = .failed("e")
        let t3 = UniTask(inputType: .urlDownload, sourceURL: "https://c.com")
        t3.status = .pending

        [t1, t2, t3].forEach { scheduler.enqueue($0) }
        scheduler.clearCompleted()
        XCTAssertEqual(scheduler.allTasks.count, 1)
    }

    func testBatchEnqueue() {
        let urls = (0..<10).map { "https://example.com/test\($0).mp3" }
        for url in urls {
            scheduler.enqueue(UniTask(inputType: .urlDownload, sourceURL: url))
        }
        XCTAssertEqual(scheduler.allTasks.count, 10)
    }

    func testEmptyURL() {
        let task = UniTask(inputType: .urlDownload, sourceURL: "")
        scheduler.enqueue(task)
        XCTAssertEqual(scheduler.allTasks.count, 1)
    }
}
