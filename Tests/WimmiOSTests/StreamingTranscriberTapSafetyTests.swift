import XCTest
@testable import WimmiOSApp

@MainActor
final class StreamingTranscriberTapSafetyTests: XCTestCase {
    func testTapFormatValidation() {
        XCTAssertTrue(IOSStreamingTranscriber.isUsableTapFormat(sampleRate: 48000, channelCount: 1))
        XCTAssertFalse(IOSStreamingTranscriber.isUsableTapFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(IOSStreamingTranscriber.isUsableTapFormat(sampleRate: 44100, channelCount: 0))
        XCTAssertFalse(IOSStreamingTranscriber.isUsableTapFormat(sampleRate: .nan, channelCount: 1))
    }

    func testStopWithoutStartIsSafeRepeatedly() {
        let t = IOSStreamingTranscriber(locales: ["en-US"])
        t.stopTranscribing()
        t.stopTranscribing()
    }
}
