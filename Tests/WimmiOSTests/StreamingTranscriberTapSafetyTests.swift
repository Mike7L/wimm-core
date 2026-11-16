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

    func testTapFormatMustMatchHardwareAfterRouteChange() {
        // AirPods HFP 16 kHz hardware while the stale node still reports 48 kHz.
        XCTAssertFalse(IOSStreamingTranscriber.tapFormatMatchesHardware(
            tapSampleRate: 48000, tapChannels: 1, hardwareSampleRate: 16000, hardwareChannels: 1))
        XCTAssertFalse(IOSStreamingTranscriber.tapFormatMatchesHardware(
            tapSampleRate: 0, tapChannels: 0, hardwareSampleRate: 0, hardwareChannels: 0))
        XCTAssertTrue(IOSStreamingTranscriber.tapFormatMatchesHardware(
            tapSampleRate: 16000, tapChannels: 1, hardwareSampleRate: 16000, hardwareChannels: 1))
    }

    func testRouteChangeRetryIsBounded() {
        XCTAssertNotNil(IOSStreamingTranscriber.routeChangeRetryDelay(afterAttempt: 0))
        XCTAssertNil(IOSStreamingTranscriber.routeChangeRetryDelay(afterAttempt: 3))
    }

    func testStopWithoutStartIsSafeRepeatedly() {
        let t = IOSStreamingTranscriber(locales: ["en-US"])
        t.stopTranscribing()
        t.stopTranscribing()
    }
}
