import XCTest
@testable import WimmInfrastructure

final class SilenceSplitterTests: XCTestCase {
    private func splitter(close: Double = 10) -> SilenceSplitter {
        var policy = SilenceSplitPolicy()
        policy.closeAfterSeconds = close
        return SilenceSplitter(policy: policy)
    }

    /// Number of sends while feeding `seconds` of level `rms` in 0.1 s buffers.
    private func sends(_ s: inout SilenceSplitter, rms: Float, seconds: Double) -> Int {
        (0..<Int((seconds * 10).rounded())).filter { _ in s.feed(rms: rms, seconds: 0.1) }.count
    }

    func testDefaultIsTenSecondsAndEnabled() {
        XCTAssertEqual(SilenceSplitPolicy().closeAfterSeconds, 10)
        XCTAssertTrue(SilenceSplitPolicy().isEnabled)
    }

    func testStoredSettingOverridesAndZeroDisables() {
        let defaults = UserDefaults(suiteName: "SilenceSplitterTests-\(UUID())")!
        XCTAssertEqual(SilenceSplitPolicy.stored(defaults).closeAfterSeconds, 10)
        defaults.set(15.0, forKey: DefaultsKey.captureSilenceSplitSeconds)
        XCTAssertEqual(SilenceSplitPolicy.stored(defaults).closeAfterSeconds, 15)
        defaults.set(0.0, forKey: DefaultsKey.captureSilenceSplitSeconds)
        XCTAssertFalse(SilenceSplitPolicy.stored(defaults).isEnabled)
    }

    func testSpeechThenLongSilenceSendsOnce() {
        var s = splitter()
        XCTAssertEqual(sends(&s, rms: 0.05, seconds: 5), 0)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 9), 0)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 3), 1)
    }

    func testAnHourOfSilenceAfterwardsDoesNotSendAgain() {
        var s = splitter()
        _ = sends(&s, rms: 0.05, seconds: 2)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 11), 1)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 3600), 0)
    }

    func testNextNoteSendsAfterItsOwnSpeechAndSilence() {
        var s = splitter()
        _ = sends(&s, rms: 0.05, seconds: 2)
        _ = sends(&s, rms: 0, seconds: 11)
        _ = sends(&s, rms: 0, seconds: 600)
        XCTAssertEqual(sends(&s, rms: 0.05, seconds: 1), 0)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 11), 1)
    }

    func testShortPausesDoNotSplit() {
        var s = splitter()
        for _ in 0..<5 {
            XCTAssertEqual(sends(&s, rms: 0.05, seconds: 2), 0)
            XCTAssertEqual(sends(&s, rms: 0, seconds: 8), 0)
        }
    }

    func testRestartAfterManualSendCountsFromScratch() {
        var s = splitter()
        _ = sends(&s, rms: 0.05, seconds: 1)
        _ = sends(&s, rms: 0, seconds: 8)
        s.restart()
        _ = sends(&s, rms: 0.05, seconds: 1)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 8), 0)
    }

    func testDisabledNeverSplits() {
        var s = splitter(close: 0)
        _ = sends(&s, rms: 0.05, seconds: 1)
        XCTAssertEqual(sends(&s, rms: 0, seconds: 7200), 0)
    }
}
