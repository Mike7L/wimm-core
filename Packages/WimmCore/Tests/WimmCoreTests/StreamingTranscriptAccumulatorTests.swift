import XCTest
@testable import WimmDomain

final class StreamingTranscriptAccumulatorTests: XCTestCase {
    func testPartialRevisionsReplaceRatherThanDuplicateCurrentUtterance() {
        var accumulator = StreamingTranscriptAccumulator()

        XCTAssertEqual(
            accumulator.update(partial: "позвони Пете", isFinalized: false),
            "позвони Пете"
        )
        XCTAssertEqual(
            accumulator.update(partial: "позвони Петру", isFinalized: false),
            "позвони Петру"
        )
        XCTAssertEqual(accumulator.committedText, "")
    }

    func testFinalizedUtteranceSurvivesPartialReset() {
        var accumulator = StreamingTranscriptAccumulator()

        XCTAssertEqual(
            accumulator.update(partial: "первая законченная фраза", isFinalized: true),
            "первая законченная фраза"
        )
        XCTAssertEqual(
            accumulator.update(partial: "новый хвост", isFinalized: false),
            "первая законченная фраза новый хвост"
        )
    }

    func testMultipleFinalizedUtterancesBuildRecordingWideTranscript() {
        var accumulator = StreamingTranscriptAccumulator()

        _ = accumulator.update(partial: "первая фраза", isFinalized: true)
        _ = accumulator.update(partial: "вторая", isFinalized: false)
        _ = accumulator.update(partial: "вторая фраза", isFinalized: true)

        XCTAssertEqual(
            accumulator.update(partial: "третий partial", isFinalized: false),
            "первая фраза вторая фраза третий partial"
        )
        XCTAssertEqual(accumulator.committedText, "первая фраза вторая фраза")
    }

    func testCurrentPartialCanBeCommittedBeforeSessionRestart() {
        var accumulator = StreamingTranscriptAccumulator()

        _ = accumulator.update(partial: "текст до ошибки", isFinalized: false)
        XCTAssertEqual(accumulator.commitCurrentPartial(), "текст до ошибки")
        XCTAssertEqual(
            accumulator.update(partial: "после перезапуска", isFinalized: false),
            "текст до ошибки после перезапуска"
        )
    }

    func testResetClearsAllSessionState() {
        var accumulator = StreamingTranscriptAccumulator()
        _ = accumulator.update(partial: "старый текст", isFinalized: true)

        accumulator.reset()

        XCTAssertEqual(accumulator.text, "")
        XCTAssertEqual(accumulator.committedText, "")
        XCTAssertEqual(accumulator.currentPartial, "")
    }
}
