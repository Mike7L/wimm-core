import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmiOSApp

@MainActor
final class ProcessingQueueTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func note(_ name: String) -> URL { directory.appendingPathComponent(name) }

    func testRunsJobsOneAtATimeInOrder() async {
        let queue = ProcessingQueue(storeURL: nil)
        let performer = StubPerformer()
        queue.performer = performer
        queue.enqueue([note("a.m4a"), note("b.txt")], kind: .auto)

        queue.start()
        await performer.waitForCalls(2)
        await waitUntilIdle(queue)

        XCTAssertEqual(performer.calls, ["a.m4a", "b.txt"])
        XCTAssertEqual(performer.maxConcurrent, 1)
        XCTAssertEqual(queue.jobs.map(\.state), [.done, .done])
    }

    func testSameNoteIsNotQueuedTwice() {
        let queue = ProcessingQueue(storeURL: nil)
        let first = queue.enqueue(note("a.m4a"), kind: .auto)
        let second = queue.enqueue(note("a.m4a"), kind: .transcribe)
        XCTAssertEqual(first, second)
        XCTAssertEqual(queue.jobs.count, 1)
    }

    func testFailureIsRecordedAndTheQueueMovesOn() async {
        let queue = ProcessingQueue(storeURL: nil)
        let performer = StubPerformer()
        performer.errors["a.m4a"] = NoteReprocessingError.transcriptionFailed("test failure")
        queue.performer = performer
        queue.enqueue([note("a.m4a"), note("b.m4a")], kind: .auto)

        queue.start()
        await waitUntilIdle(queue)

        XCTAssertEqual(queue.jobs.map(\.state), [.failed(NoteReprocessingError.transcriptionFailed("test failure").localizedDescription), .done])
    }

    func testMissingKeyPausesInsteadOfFailingEveryJob() async {
        let queue = ProcessingQueue(storeURL: nil)
        let performer = StubPerformer()
        performer.errors["a.m4a"] = NoteReprocessingError.missingKey(.gemini)
        queue.performer = performer
        queue.enqueue([note("a.m4a"), note("b.m4a")], kind: .auto)

        queue.start()
        await waitUntilIdle(queue)

        XCTAssertTrue(queue.isPaused)
        XCTAssertEqual(performer.calls, ["a.m4a"])
        XCTAssertEqual(queue.jobs.last?.state, .queued)
    }

    func testPauseLetsTheCurrentJobFinish() async {
        let queue = ProcessingQueue(storeURL: nil)
        let performer = StubPerformer()
        performer.holdNext = true
        queue.performer = performer
        queue.enqueue([note("a.m4a"), note("b.m4a")], kind: .auto)

        queue.start()
        await performer.waitForCalls(1)
        queue.pause()
        performer.release()
        await waitUntilIdle(queue)

        XCTAssertEqual(queue.jobs.map(\.state), [.done, .queued])
        queue.start()
        await waitUntilIdle(queue)
        XCTAssertEqual(queue.jobs.map(\.state), [.done, .done])
    }

    func testMenuRunJumpsTheQueueAndReportsTheEnd() async {
        let queue = ProcessingQueue(storeURL: nil)
        let performer = StubPerformer()
        performer.outcomes["c.m4a"] = .skipped
        queue.performer = performer
        queue.enqueue([note("a.m4a"), note("b.m4a")], kind: .auto)
        queue.pause()

        let end = await queue.run(note("c.m4a"), kind: .analyze)

        XCTAssertEqual(end, .skipped)
        XCTAssertEqual(performer.calls.first, "c.m4a")
        XCTAssertEqual(performer.kinds.first, .analyze)
        await waitUntilIdle(queue)
    }

    func testQueueSurvivesARelaunchAndARunningJobComesBackQueued() throws {
        let store = directory.appendingPathComponent("queue.json")
        let queue = ProcessingQueue(storeURL: store)
        queue.enqueue([note("a.m4a"), note("b.m4a")], kind: .auto)
        queue.pause()
        // Simulate the app dying mid-job.
        var stored = try JSONSerialization.jsonObject(with: Data(contentsOf: store)) as! [String: Any]
        var jobs = stored["jobs"] as! [[String: Any]]
        jobs[0]["state"] = ["running": [String: Any]()]
        stored["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: stored).write(to: store)

        let relaunched = ProcessingQueue(storeURL: store)

        XCTAssertEqual(relaunched.jobs.map(\.state), [.queued, .queued])
        XCTAssertEqual(relaunched.jobs.map { $0.url.lastPathComponent }, ["a.m4a", "b.m4a"])
        XCTAssertTrue(relaunched.isPaused)
    }

    func testOnDeviceTranscriptsCountAsNeedingCloudTranscription() {
        XCTAssertTrue(AppState.isOnDeviceProvider(""))
        XCTAssertTrue(AppState.isOnDeviceProvider("native"))
        XCTAssertTrue(AppState.isOnDeviceProvider("apple-speech"))
        XCTAssertFalse(AppState.isOnDeviceProvider("gemini"))
        XCTAssertFalse(AppState.isOnDeviceProvider("openrouter"))
    }

    func testLegacyAnalysisJobIsSkipped() async throws {
        let appState = AppState(startServices: false)
        let outcome = try await appState.perform(.analyze, url: note("test.m4a"))
        XCTAssertEqual(outcome, .skipped)
    }

    private func waitUntilIdle(_ queue: ProcessingQueue) async {
        for _ in 0..<200 where queue.isRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(queue.isRunning)
    }
}

@MainActor
private final class StubPerformer: ProcessingPerformer {
    var errors: [String: Error] = [:]
    var outcomes: [String: ProcessingOutcome] = [:]
    var holdNext = false
    private(set) var calls: [String] = []
    private(set) var kinds: [ProcessingJobKind] = []
    private(set) var maxConcurrent = 0
    private var concurrent = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func perform(_ kind: ProcessingJobKind, url: URL) async throws -> ProcessingOutcome {
        let name = url.lastPathComponent
        calls.append(name)
        kinds.append(kind)
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
        defer { concurrent -= 1 }
        callWaiters.removeAll { count, continuation in
            guard calls.count >= count else { return false }
            continuation.resume()
            return true
        }
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        if let error = errors[name] { throw error }
        return outcomes[name] ?? .done
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func waitForCalls(_ count: Int) async {
        guard calls.count < count else { return }
        await withCheckedContinuation { callWaiters.append((count, $0)) }
    }
}
