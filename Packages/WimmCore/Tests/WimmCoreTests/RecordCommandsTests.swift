import XCTest
import WimmDomain
@testable import WimmTUI

final class RecordCommandsTests: XCTestCase {
    func testResolveRecordedTranscriptPrefersFinalText() {
        let value = resolveRecordedTranscript(
            finalText: "final transcript",
            liveFallback: "live partial"
        )
        XCTAssertEqual(value, "final transcript")
    }

    func testResolveRecordedTranscriptFallsBackToLiveWhenFinalEmpty() {
        let value = resolveRecordedTranscript(
            finalText: "   \n",
            liveFallback: "live partial"
        )
        XCTAssertEqual(value, "live partial")
    }

    func testResolveRecordedTranscriptReturnsEmptyWhenBothEmpty() {
        let value = resolveRecordedTranscript(
            finalText: "   ",
            liveFallback: " \n "
        )
        XCTAssertEqual(value, "")
    }
}
