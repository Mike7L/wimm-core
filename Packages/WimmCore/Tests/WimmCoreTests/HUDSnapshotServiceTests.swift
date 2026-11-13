import XCTest
import WimmDomain

final class HUDSnapshotServiceTests: XCTestCase {
    func testMakeSnapshotBuildsQueueCountsAndRecentRows() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let notes = [
            CapturedNote(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                createdAt: base.addingTimeInterval(10),
                text: "Meaningful note",
                audioPath: nil,
                status: .pendingAnalysis
            ),
            CapturedNote(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                createdAt: base.addingTimeInterval(20),
                text: "",
                audioPath: nil,
                status: .failed(reason: "empty", retryable: true)
            )
        ]
        let queue = QueueStatusSnapshot(
            pendingCount: 1,
            completedCount: 0,
            failedRetryableCount: 1,
            failedNonRetryableCount: 0,
            failedItems: []
        )

        let snapshot = HUDSnapshotService.makeSnapshot(
            notes: notes,
            queue: queue,
            generatedAt: base,
            recentLimit: 2
        )

        XCTAssertEqual(snapshot.generatedAt, base)
        XCTAssertEqual(snapshot.total, 2)
        XCTAssertEqual(snapshot.pending, 1)
        XCTAssertEqual(snapshot.failedRetryable, 1)
        XCTAssertEqual(snapshot.recent.count, 2)
        XCTAssertEqual(snapshot.recent[0].shortID, "11111111")
        XCTAssertEqual(snapshot.recent[0].statusLabel, "PENDING")
        XCTAssertEqual(snapshot.recent[0].title, "Meaningful note")
    }

    func testMakeHUDReviewStateUsesNormalizedPreview() {
        let note = CapturedNote(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "  first line\nsecond line  ",
            audioPath: nil,
            status: .pendingAnalysis
        )

        let review = makeHUDReviewState(from: note)
        XCTAssertEqual(review.shortID, "33333333")
        XCTAssertEqual(review.preview, "first line second line")
    }
}
