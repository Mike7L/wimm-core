import XCTest
@testable import WimmInfrastructure

final class UnifiedModelHistoryTests: XCTestCase {
    @MainActor
    func testManualHistoryIsBoundedPerTypeIncludingFailures() {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 3)
        let active = manager.beginManualJob(type: .analysis, input: "active", engine: "test")
        for type in [ModelType.analysis, .transcription] {
            for n in 0..<40 {
                let id = manager.beginManualJob(type: type, input: "\(n)", engine: "test")
                manager.completeManualJob(jobId: id, error: n.isMultiple(of: 2) ? "failed" : nil, output: "\(n)")
            }
        }
        XCTAssertEqual(manager.jobs.count, 7)
        XCTAssertEqual(manager.getJob(id: active)?.status, .processing)
        XCTAssertEqual(manager.jobs.filter { $0.type == .transcription }.map(\.input), ["37", "38", "39"])
    }

    @MainActor
    func testFireAndForgetCompletionIsBounded() async throws {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 3)
        manager.register(handler: EchoHandler(), for: .processing)
        for n in 0..<260 { manager.submit(type: .processing, input: "\(n)", engine: "test") }
        try await drain(manager)
        XCTAssertEqual(manager.jobs.count, 3)
        XCTAssertTrue(manager.jobs.allSatisfy { $0.status == .completed })
    }

    @MainActor
    func testCancellingAndClearingRunningJobStillReleasesExecutionSlot() async throws {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 0)
        let barrier = QueueBarrier()
        manager.register(handler: HoldingHandler(barrier: barrier), for: .processing)
        let first = manager.submit(type: .processing, input: "first", engine: "test")
        let second = manager.submit(type: .processing, input: "second", engine: "test", retainResult: true)
        while !(await barrier.didStart) { await Task.yield() }
        manager.cancel(jobId: first)
        manager.clearCompleted()
        XCTAssertNotNil(manager.getJob(id: first), "keep the job until finish releases its running slot")
        await barrier.open()
        try await drain(manager)
        let result = try await manager.waitForCompletion(jobId: second)
        XCTAssertEqual(result, "second")
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    @MainActor
    func testFrontLoadedBatchSurvivesPruningAndClearUntilEachResultIsRead() async throws {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 3)
        manager.register(handler: EchoHandler(), for: .processing)
        let ids = (0..<240).map {
            manager.submit(type: .processing, input: "result-\($0)", engine: "test", retainResult: true)
        }
        try await drain(manager)
        XCTAssertEqual(manager.jobs.count, ids.count)
        manager.clearCompleted()
        XCTAssertEqual(manager.jobs.count, ids.count, "UI clear must not discard unread batch results")
        for (n, id) in ids.enumerated() {
            let output = try await manager.waitForCompletion(jobId: id)
            XCTAssertEqual(output, "result-\(n)")
        }
        XCTAssertEqual(manager.jobs.count, 3)
        manager.clearCompleted()
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    @MainActor
    func testAbandonedBatchReleasesUnreadResults() async throws {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 2)
        manager.register(handler: EchoHandler(), for: .processing)
        let ids = (0..<30).map {
            manager.submit(type: .processing, input: "\($0)", engine: "test", retainResult: true)
        }
        try await drain(manager)
        manager.releaseResults(for: ids)
        XCTAssertEqual(manager.jobs.count, 2)
    }

    @MainActor
    func testActiveWaiterSurvivesClearAndZeroHistory() async throws {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 0)
        manager.register(handler: DelayedHandler(), for: .processing)
        let id = manager.submit(type: .processing, input: "kept", engine: "test")
        let wait = Task { try await manager.waitForCompletion(jobId: id) }
        try await drain(manager)
        manager.clearCompleted()
        let result = try await wait.value
        XCTAssertEqual(result, "kept")
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    @MainActor
    func testCancelledWaitDoesNotLeakReservationOrCancelExecution() async throws {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 0)
        manager.register(handler: DelayedHandler(), for: .processing)
        let id = manager.submit(type: .processing, input: "kept", engine: "test", retainResult: true)
        let wait = Task { try await manager.waitForCompletion(jobId: id) }
        await Task.yield()
        wait.cancel()
        do { _ = try await wait.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        try await drain(manager)
        XCTAssertTrue(manager.jobs.isEmpty)
    }

    @MainActor
    func testCancelledQueuedBatchIsPrunedAfterRelease() {
        let manager = UnifiedModelManager(maxFinishedHistoryPerType: 2)
        manager.setPaused(true, for: .processing)
        let ids = (0..<30).map {
            manager.submit(type: .processing, input: "\($0)", engine: "test", retainResult: true)
        }
        manager.cancelAll(for: .processing)
        XCTAssertEqual(manager.jobs.count, ids.count)
        manager.releaseResults(for: ids)
        XCTAssertEqual(manager.jobs.count, 2)
        XCTAssertEqual(manager.queueSnapshot(for: .processing).queued, 0)
    }

    @MainActor
    private func drain(_ manager: UnifiedModelManager) async throws {
        for _ in 0..<1000 {
            if !manager.jobs.contains(where: { $0.status == .processing || $0.status == .queued }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("queue did not drain")
    }
}

private struct EchoHandler: ModelJobHandler {
    func process(job: ModelJob, progress: @Sendable @escaping (Double) -> Void) async throws -> String { job.input }
}

private struct DelayedHandler: ModelJobHandler {
    func process(job: ModelJob, progress: @Sendable @escaping (Double) -> Void) async throws -> String {
        try await Task.sleep(for: .milliseconds(50))
        return job.input
    }
}

private struct HoldingHandler: ModelJobHandler {
    let barrier: QueueBarrier
    func process(job: ModelJob, progress: @Sendable @escaping (Double) -> Void) async throws -> String {
        if job.input == "first" { await barrier.wait() }
        return job.input
    }
}

private actor QueueBarrier {
    var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        didStart = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}
