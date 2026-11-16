import XCTest
@testable import WimmStudio

final class AirPodsPressFilterTests: XCTestCase {
    func testUnmuteIsNeverAPress() {
        var filter = AirPodsPressFilter()
        XCTAssertFalse(filter.accept(muted: false, at: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(filter.accept(muted: true, at: Date(timeIntervalSince1970: 0)))
    }

    /// The 2026-11-15 storm: mute-state callbacks about twice a second for 90 s cut one
    /// recording into ~158 sub-second notes. At most one press per window may pass.
    func testCallbackStormSendsAtMostOncePerWindow() {
        var filter = AirPodsPressFilter()
        let start = Date(timeIntervalSince1970: 1_000)
        var accepted: [Date] = []
        for i in 0..<180 {
            let now = start.addingTimeInterval(Double(i) * 0.5)
            if filter.accept(muted: i % 2 == 0, at: now) { accepted.append(now) }
        }
        XCTAssertLessThanOrEqual(accepted.count, 45)
        for (a, b) in zip(accepted, accepted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.timeIntervalSince(a), AirPodsPressFilter.minimumInterval)
        }
    }

    func testSeparatePressesBothPass() {
        var filter = AirPodsPressFilter()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(filter.accept(muted: true, at: start))
        XCTAssertFalse(filter.accept(muted: true, at: start.addingTimeInterval(0.4)))
        XCTAssertTrue(filter.accept(muted: true, at: start.addingTimeInterval(5)))
    }

    /// Stating "unmuted" echoes back as an unmuted callback: the echo must not be answered.
    func testUnmutedStatementIsNotRepeatedForItsOwnEcho() {
        var filter = AirPodsPressFilter()
        let start = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(filter.shouldStateUnmuted(at: start))
        XCTAssertFalse(filter.shouldStateUnmuted(at: start.addingTimeInterval(0.5)))
        XCTAssertTrue(filter.shouldStateUnmuted(at: start.addingTimeInterval(AirPodsPressFilter.statementInterval)))
    }
}
