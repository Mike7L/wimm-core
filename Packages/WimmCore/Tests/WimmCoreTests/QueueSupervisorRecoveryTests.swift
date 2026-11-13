import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

final class QueueSupervisorRecoveryTests: XCTestCase {
    private var tempDir: URL!
    private var storage: FileSystemAdapter!
    private var supervisor: QueueSupervisor!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-queue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = FileSystemAdapter(rootDirectory: tempDir)
        supervisor = QueueSupervisor(storage: storage, analysis: StubAnalysis())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testPendingQueueItemProcessedAfterRestart() async throws {
        // Simulate first app run: note is saved and stays pending on disk.
        _ = try await storage.saveRecording(data: Data(), fileName: "r1.m4a", initialText: "transcribed text")

        // Simulate app restart: new adapter + new supervisor, no in-memory state.
        let restartedStorage = FileSystemAdapter(rootDirectory: tempDir)
        let restartedSupervisor = QueueSupervisor(storage: restartedStorage, analysis: StubAnalysis())

        let processed = try await restartedSupervisor.processQueue()
        XCTAssertEqual(processed, 1)

        let notes = try await restartedStorage.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].status, .completed)
        XCTAssertEqual(notes[0].card?.title, "Stub Title")
    }

    func testRetryFailedTasksRequeuesOnlyRetryable() async throws {
        _ = try await storage.saveRecording(data: Data(), fileName: "r2.m4a", initialText: "t1")
        _ = try await storage.saveRecording(data: Data(), fileName: "r3.m4a", initialText: "t2")

        var all = try await storage.loadAll()
        XCTAssertEqual(all.count, 2)

        var first = all[0]; var second = all[1]
        first.status = .failed(reason: "rate limit", retryable: true)
        second.status = .failed(reason: "bad request", retryable: false)
        try await storage.updateNote(first)
        try await storage.updateNote(second)

        let result = try await supervisor.retryFailedTasks()

        XCTAssertEqual(result.retried, 1)
        XCTAssertEqual(result.processed, 1)

        let after = try await storage.loadAll()
        XCTAssertEqual(after.filter { $0.status == .completed }.count, 1)
        XCTAssertTrue(after.contains(where: {
            if case .failed(_, false) = $0.status { return true }
            return false
        }))
    }

    func testRetryFailedTasksAllIncludesNonRetryable() async throws {
        _ = try await storage.saveRecording(data: Data(), fileName: "a1.m4a", initialText: "x1")
        _ = try await storage.saveRecording(data: Data(), fileName: "a2.m4a", initialText: "x2")

        var all = try await storage.loadAll()
        all[0].status = .failed(reason: "rate limit", retryable: true)
        all[1].status = .failed(reason: "invalid payload", retryable: false)
        try await storage.updateNote(all[0])
        try await storage.updateNote(all[1])

        let result = try await supervisor.retryFailedTasks(includeNonRetryable: true)

        XCTAssertEqual(result.retried, 2)
        XCTAssertEqual(result.processed, 2)
        let afterAll = try await storage.loadAll()
        XCTAssertEqual(afterAll.filter { $0.status == .completed }.count, 2)
    }

    func testRetryFailedTasksByIDPrefixTargetsSingleNote() async throws {
        let n1 = try await storage.saveRecording(data: Data(), fileName: "b1.m4a", initialText: "x1")
        let n2 = try await storage.saveRecording(data: Data(), fileName: "b2.m4a", initialText: "x2")

        var all = try await storage.loadAll()
        for i in all.indices {
            all[i].status = .failed(reason: "manual retry", retryable: false)
            try await storage.updateNote(all[i])
        }

        let result = try await supervisor.retryFailedTasks(idPrefix: String(n1.id.uuidString.prefix(8)))

        XCTAssertEqual(result.retried, 1)
        XCTAssertEqual(result.processed, 1)

        let after = try await storage.loadAll()
        XCTAssertEqual(after.first { $0.id == n1.id }?.status, .completed)
        if case .failed(_, false) = after.first(where: { $0.id == n2.id })?.status {
            XCTAssertTrue(true)
        } else {
            XCTFail("Second note should remain failed(non-retryable)")
        }
    }

    func testProcessQueueWithLimitProcessesOnlySubset() async throws {
        _ = try await storage.saveRecording(data: Data(), fileName: "l1.m4a", initialText: "a")
        _ = try await storage.saveRecording(data: Data(), fileName: "l2.m4a", initialText: "b")
        _ = try await storage.saveRecording(data: Data(), fileName: "l3.m4a", initialText: "c")

        let processed = try await supervisor.processQueue(limit: 2)
        XCTAssertEqual(processed, 2)

        let notes = try await storage.loadAll()
        XCTAssertEqual(notes.filter { $0.status == .completed }.count, 2)
        XCTAssertEqual(notes.filter { $0.status == .pendingAnalysis }.count, 1)
    }

    func testPreviewProcessQueueDoesNotMutateState() async throws {
        _ = try await storage.saveRecording(data: Data(), fileName: "p1.m4a", initialText: "a")
        _ = try await storage.saveRecording(data: Data(), fileName: "p2.m4a", initialText: "b")

        let planned = try await supervisor.previewProcessQueue(limit: 1)
        XCTAssertEqual(planned.count, 1)

        let after = try await storage.loadAll()
        XCTAssertEqual(after.filter { $0.status == .pendingAnalysis }.count, 2)
        XCTAssertEqual(after.filter { $0.status == .completed }.count, 0)
    }

    func testPreviewRetryFailedTasksDoesNotMutateState() async throws {
        _ = try await storage.saveRecording(data: Data(), fileName: "pr1.m4a", initialText: "a")
        _ = try await storage.saveRecording(data: Data(), fileName: "pr2.m4a", initialText: "b")

        var notes = try await storage.loadAll()
        notes[0].status = .failed(reason: "rate limit", retryable: true)
        notes[1].status = .failed(reason: "bad request", retryable: false)
        try await storage.updateNote(notes[0])
        try await storage.updateNote(notes[1])

        let planned = try await supervisor.previewRetryFailedTasks()
        XCTAssertEqual(planned.count, 1)

        let after = try await storage.loadAll()
        XCTAssertEqual(after.filter { if case .failed = $0.status { return true }; return false }.count, 2)
        XCTAssertEqual(after.filter { $0.status == .pendingAnalysis }.count, 0)
    }
}

// DeterministicAnalysis: fixed "Recovered" card — in TestDoubles.swift as StubAnalysis with default card
