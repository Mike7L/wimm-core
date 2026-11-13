import XCTest
#if os(macOS)
import Darwin
#endif
@testable import WimmInfrastructure

final class LocalInferenceSchedulerTests: XCTestCase {
    #if os(macOS)
    func testFileAndBacklogUseLowerThreadQoSDespiteHighPriorityCaller() async throws {
        guard #available(macOS 15, *) else { throw XCTSkip("Task executor preference requires macOS 15") }
        for (priority, expected) in [(LocalInferenceScheduler.Priority.file, QOS_CLASS_UTILITY),
                                     (.background, QOS_CLASS_BACKGROUND)] {
            let task = Task.detached(priority: .userInitiated) {
                try await LocalInferenceScheduler().withPermit(priority: priority) {
                    let before = qos_class_self().rawValue
                    try await Task.sleep(for: .milliseconds(2))
                    return [before, qos_class_self().rawValue]
                }
            }
            let actual = try await task.value
            XCTAssertEqual(actual, [expected.rawValue, expected.rawValue])
        }
    }

    func testLiveInferenceRetainsInteractiveThreadQoS() async throws {
        let task = Task.detached(priority: .userInitiated) {
            try await LocalInferenceScheduler().withPermit(priority: .live) { qos_class_self().rawValue }
        }
        let actual = try await task.value
        XCTAssertGreaterThanOrEqual(actual, QOS_CLASS_USER_INITIATED.rawValue)
    }
    #endif

    func testLiveSessionDefersBacklogAcrossRefreshGaps() async throws {
        let scheduler = LocalInferenceScheduler()
        let session = await scheduler.beginLiveSession()
        let events = InferenceEvents()
        let background = Task {
            try await scheduler.withPermit(priority: .background) { await events.add("background") }
        }
        try await pending(1, scheduler)
        for _ in 0..<3 {
            try await scheduler.withPermit(priority: .live) { await events.add("live") }
        }
        let during = await events.values
        XCTAssertEqual(during, ["live", "live", "live"])
        await scheduler.endLiveSession(session)
        try await background.value
        let after = await events.values
        XCTAssertEqual(after.last, "background")
    }

    func testCancellationRemovesWaitingWork() async throws {
        let scheduler = LocalInferenceScheduler()
        let session = await scheduler.beginLiveSession()
        let events = InferenceEvents()
        let work = Task {
            try await scheduler.withPermit(priority: .background) { await events.add("should not run") }
        }
        try await pending(1, scheduler)
        work.cancel()
        do { try await work.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let count = await scheduler.pendingCount
        XCTAssertEqual(count, 0)
        await scheduler.endLiveSession(session)
        let values = await events.values
        XCTAssertTrue(values.isEmpty)
    }

    func testRunningSplitCompletesWhenLiveSessionBeginsAndNewWorkWaits() async throws {
        let scheduler = LocalInferenceScheduler()
        let barrier = InferenceBarrier()
        let running = Task {
            try await scheduler.withPermit(priority: .background) {
                await barrier.started()
                await barrier.wait()
                return "split ready to store"
            }
        }
        while !(await barrier.didStart) { await Task.yield() }
        let session = await scheduler.beginLiveSession()
        let events = InferenceEvents()
        let waiting = Task { try await scheduler.withPermit(priority: .background) { await events.add("next") } }
        try await pending(1, scheduler)
        await barrier.open()
        let result = try await running.value
        XCTAssertEqual(result, "split ready to store")
        let values = await events.values
        XCTAssertTrue(values.isEmpty)
        await scheduler.endLiveSession(session)
        try await waiting.value
    }

    func testSerializesLoadAndKeepsFIFOWithinPriority() async throws {
        let scheduler = LocalInferenceScheduler()
        let session = await scheduler.beginLiveSession()
        let events = InferenceEvents()
        var tasks: [Task<Void, Error>] = []
        for i in 0..<40 {
            tasks.append(Task {
                try await scheduler.withPermit(priority: .background) {
                    await events.enter(i)
                    try await Task.sleep(for: .milliseconds(1))
                    await events.leave()
                }
            })
            try await pending(i + 1, scheduler)
        }
        await scheduler.endLiveSession(session)
        for task in tasks { try await task.value }
        let order = await events.order
        let maximum = await events.maximum
        XCTAssertEqual(order, Array(0..<40))
        XCTAssertEqual(maximum, 1)
    }

    func testThrowAndCancelledOperationReleasePermit() async throws {
        let scheduler = LocalInferenceScheduler()
        let work = Task {
            try await scheduler.withPermit(priority: .file) {
                try await Task.sleep(for: .seconds(60))
            }
        }
        await Task.yield()
        work.cancel()
        do { try await work.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        let result = try await scheduler.withPermit(priority: .file) { 42 }
        XCTAssertEqual(result, 42)
    }

    func testCompletedResultSurvivesCancellationDuringInference() async throws {
        let scheduler = LocalInferenceScheduler()
        let barrier = InferenceBarrier()
        let work = Task {
            try await scheduler.withPermit(priority: .background) {
                await barrier.started()
                await barrier.wait() // Core ML may finish even after the background time expires.
                return "store this split"
            }
        }
        while !(await barrier.didStart) { await Task.yield() }
        work.cancel()
        await barrier.open()
        let result = try await work.value
        XCTAssertEqual(result, "store this split")
        let next = try await scheduler.withPermit(priority: .file) { 42 }
        XCTAssertEqual(next, 42)
    }

    func testOneEndingSessionDoesNotReleaseAnotherRecording() async throws {
        let scheduler = LocalInferenceScheduler()
        let first = await scheduler.beginLiveSession()
        let second = await scheduler.beginLiveSession()
        let events = InferenceEvents()
        let waiting = Task { try await scheduler.withPermit(priority: .file) { await events.add("file") } }
        try await pending(1, scheduler)
        await scheduler.endLiveSession(first)
        let count = await scheduler.pendingCount
        XCTAssertEqual(count, 1)
        await scheduler.endLiveSession(second)
        try await waiting.value
    }

    private func pending(_ count: Int, _ scheduler: LocalInferenceScheduler) async throws {
        for _ in 0..<1000 {
            if await scheduler.pendingCount == count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("waiters did not reach \(count)")
    }
}

private actor InferenceEvents {
    var values: [String] = []
    var order: [Int] = []
    var active = 0
    var maximum = 0
    func add(_ value: String) { values.append(value) }
    func enter(_ value: Int) { order.append(value); active += 1; maximum = max(maximum, active) }
    func leave() { active -= 1 }
}

private actor InferenceBarrier {
    var didStart = false
    private var continuation: CheckedContinuation<Void, Never>?
    func started() { didStart = true }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
