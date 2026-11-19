import XCTest
@testable import WimmiOSApp

final class RecordingHeartRateTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "RecordingHeartRateTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testSettingIsOffByDefault() {
        let d = freshDefaults()
        XCTAssertFalse(RecordingHeartRateSetting.isEnabled(in: d))
        RecordingHeartRateSetting.set(true, in: d)
        XCTAssertTrue(RecordingHeartRateSetting.isEnabled(in: d))
    }

    func testTrackKeepsOffsetsFromTheNoteStart() {
        let start = Date(timeIntervalSince1970: 1_000)
        var track = HeartRateTrack(startedAt: start)
        XCTAssertTrue(track.add(bpm: 71.6, at: start.addingTimeInterval(4.0625)))
        XCTAssertTrue(track.add(bpm: 80, at: start.addingTimeInterval(9)))
        XCTAssertEqual(track.samples, [
            HeartRateSample(offset: 4.0625, bpm: 72),
            HeartRateSample(offset: 9, bpm: 80)
        ])
        let first = track.sidecarValue[0]
        XCTAssertEqual(first["offsetSeconds"] as? Double, 4.1)
        XCTAssertEqual(first["bpm"] as? Int, 72)
    }

    func testTrackDropsReadingsThatAreNotNewOrNotThisNotes() {
        let start = Date(timeIntervalSince1970: 1_000)
        var track = HeartRateTrack(startedAt: start)
        XCTAssertFalse(track.add(bpm: 70, at: start.addingTimeInterval(-2)), "reading of the previous note")
        XCTAssertTrue(track.add(bpm: 70, at: start.addingTimeInterval(5)))
        XCTAssertFalse(track.add(bpm: 70, at: start.addingTimeInterval(5)), "same reading delivered twice")
        XCTAssertFalse(track.add(bpm: 0, at: start.addingTimeInterval(6)))
        XCTAssertFalse(track.add(bpm: .nan, at: start.addingTimeInterval(7)))
        XCTAssertEqual(track.samples.count, 1)
    }
}
