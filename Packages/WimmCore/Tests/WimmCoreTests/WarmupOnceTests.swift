import XCTest
@testable import WimmInfrastructure

/// The voice warm-up ran twice in parallel and logged two identical lines (2026-11-16):
/// two players called `prepare` together and actor reentrancy let both past a `warmed` flag.
final class WarmupOnceTests: XCTestCase {
    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }

    func testConcurrentCallersShareOneRun() async throws {
        let flight = SingleFlight()
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await flight.run {
                        await counter.bump()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            try await group.waitForAll()
        }
        let runs = await counter.value
        let starts = await flight.starts
        let done = await flight.isDone
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(done)
        // Later calls return at once.
        try await flight.run { await counter.bump() }
        let after = await counter.value
        XCTAssertEqual(after, 1)
    }

    func testFailureLetsTheNextCallRetry() async throws {
        struct Boom: Error {}
        let flight = SingleFlight()
        do {
            try await flight.run { throw Boom() }
            XCTFail("expected the failure to reach the caller")
        } catch is Boom {}
        let doneAfterFailure = await flight.isDone
        XCTAssertFalse(doneAfterFailure)
        let counter = Counter()
        try await flight.run { await counter.bump() }
        let runs = await counter.value
        let starts = await flight.starts
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(starts, 2)
    }

    func testCancelledCallerDoesNotCancelTheSharedRun() async throws {
        let flight = SingleFlight()
        let counter = Counter()
        let first = Task {
            try await flight.run {
                try await Task.sleep(for: .milliseconds(100))
                await counter.bump()
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        first.cancel()
        // A second caller joins and still sees the work finish.
        try await flight.run { XCTFail("must join the running work, not start another") }
        let runs = await counter.value
        XCTAssertEqual(runs, 1)
    }

    func testWarmupOrderWaitsForTheWork() async {
        let counter = Counter()
        let started = Date()
        await WarmupOrder.wait(
            for: {
                try? await Task.sleep(for: .milliseconds(100))
                await counter.bump()
            },
            orUntil: { false },
            poll: .milliseconds(10))
        let runs = await counter.value
        XCTAssertEqual(runs, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
    }

    /// The Parakeet preload can sit behind live sessions forever; a model the live
    /// transcriber already loaded must release the voice without it.
    func testWarmupOrderStopsWaitingOnceTheConditionHolds() async {
        let ready = Counter()
        let started = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            await ready.bump()
        }
        await WarmupOrder.wait(
            for: { try? await Task.sleep(for: .seconds(30)) },
            orUntil: { await ready.value > 0 },
            poll: .milliseconds(10))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
