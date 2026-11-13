import XCTest
import WimmInfrastructure

final class AudioSilenceMapTests: XCTestCase {
    private let window = 0.2

    /// Helper: n windows of the given RMS level.
    private func windows(_ seconds: Double, _ level: Float) -> [Float] {
        Array(repeating: level, count: Int(seconds / window))
    }

    func testSpeechGapSpeechProducesOneSilence() throws {
        let rms = windows(4, 0.05) + windows(6, 0.0002) + windows(4, 0.05)
        let map = AudioSilenceMap.build(windowRMS: rms, windowSeconds: window)

        XCTAssertEqual(map.duration, 14, accuracy: 0.001)
        XCTAssertEqual(map.silences.count, 1)
        let gap = try XCTUnwrap(map.silences.first)
        // Speech padding shrinks the gap from both sides.
        XCTAssertEqual(gap.start, 4.3, accuracy: 0.05)
        XCTAssertEqual(gap.end, 9.7, accuracy: 0.05)
    }

    func testShortPauseIsNotSkippable() {
        // 0.8s pause between speech: below minimumSilenceSeconds after padding.
        let rms = windows(4, 0.05) + windows(0.8, 0.0002) + windows(4, 0.05)
        let map = AudioSilenceMap.build(windowRMS: rms, windowSeconds: window)
        XCTAssertTrue(map.silences.isEmpty)
    }

    func testUniformSpeechHasNoSilence() {
        let map = AudioSilenceMap.build(windowRMS: windows(30, 0.04), windowSeconds: window)
        XCTAssertTrue(map.silences.isEmpty)
    }

    func testQuietUniformSpeechIsNotClassifiedAsSilence() {
        // Very quiet but consistent speech (the RU quiet-speech regime): the
        // peak-fraction cap must keep the threshold below the signal.
        let map = AudioSilenceMap.build(windowRMS: windows(30, 0.0008), windowSeconds: window)
        XCTAssertTrue(map.silences.isEmpty)
    }

    func testSilentFileIsOneBigGap() {
        let map = AudioSilenceMap.build(windowRMS: windows(20, 0.00003), windowSeconds: window)
        XCTAssertEqual(map.silences, [.init(start: 0, end: 20)])
    }

    func testLeadingAndTrailingSilence() {
        let rms = windows(5, 0.0002) + windows(4, 0.05) + windows(5, 0.0002)
        let map = AudioSilenceMap.build(windowRMS: rms, windowSeconds: window)
        XCTAssertEqual(map.silences.count, 2)
        XCTAssertEqual(map.silences[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(map.silences[1].end, 14, accuracy: 0.001)
    }

    func testSkipTarget() {
        let map = AudioSilenceMap(
            duration: 20,
            silences: [.init(start: 5, end: 10), .init(start: 18, end: 20)]
        )
        // In speech: no skip.
        XCTAssertNil(map.skipTarget(at: 3))
        // Inside a gap: jump to its end.
        XCTAssertEqual(map.skipTarget(at: 6), 10)
        // Near the gap's end: remaining too short to bother.
        XCTAssertNil(map.skipTarget(at: 9.8))
        // Trailing silence: jump to the file end.
        XCTAssertEqual(map.skipTarget(at: 18.2), 20)
    }

    func testEmptyInput() {
        let map = AudioSilenceMap.build(windowRMS: [], windowSeconds: window)
        XCTAssertEqual(map.duration, 0)
        XCTAssertTrue(map.silences.isEmpty)
    }
}
