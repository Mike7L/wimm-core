import XCTest
@testable import WimmStudio

final class HUDSoundTests: XCTestCase {
    func testEveryCueIsShortQuietAndDeterministic() {
        for cue in HUDSound.Cue.allCases {
            let samples = HUDSoundSynth.samples(for: cue)
            let seconds = Double(samples.count) / HUDSoundSynth.sampleRate
            let peak = samples.map(abs).max() ?? 0
            XCTAssertGreaterThan(seconds, 0.05, "\(cue)")
            XCTAssertLessThan(seconds, 0.7, "\(cue)")
            XCTAssertGreaterThan(peak, 0.005, "\(cue) is silent")
            XCTAssertLessThan(peak, 0.5, "\(cue) is louder than a quiet cue")
            XCTAssertEqual(samples, HUDSoundSynth.samples(for: cue), "\(cue)")
        }
    }

    func testWavHeaderDescribesTheSamples() {
        let samples = HUDSoundSynth.samples(for: .start)
        let data = HUDSoundSynth.wav(samples)
        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        let dataSize = data[40..<44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        XCTAssertEqual(dataSize, samples.count * 2)
    }

    @MainActor
    func testRecordedCuesNeedHeadphones() {
        for cue in [HUDSound.Cue.page, .saved, .lockOn, .lockOff] {
            XCTAssertFalse(HUDSound.shouldPlay(cue, recording: true, headphones: false, interfaceSounds: true), "\(cue)")
            XCTAssertTrue(HUDSound.shouldPlay(cue, recording: true, headphones: true, interfaceSounds: true), "\(cue)")
            XCTAssertTrue(HUDSound.shouldPlay(cue, recording: false, headphones: false, interfaceSounds: true), "\(cue)")
        }
        for cue in [HUDSound.Cue.start, .stop, .vikHeard, .vikDone, .fail, .trouble] {
            XCTAssertTrue(HUDSound.shouldPlay(cue, recording: true, headphones: false, interfaceSounds: true), "\(cue)")
        }
        XCTAssertFalse(HUDSound.shouldPlay(.start, recording: false, headphones: true, interfaceSounds: false))
    }

    func testRolloverPlaysPageOnlyOutsideAlyona() {
        var tracker = HUDCueTracker()
        var state = HUDCueTracker.Snapshot(recording: true)
        XCTAssertEqual(tracker.cues(for: state), [])
        state.sendCount = 1
        XCTAssertEqual(tracker.cues(for: state), [.page])
        state.vik = .finishing; state.headphones = true; state.sendCount = 2
        XCTAssertEqual(tracker.cues(for: state), [.vikHeard])
    }

    func testTroubleSoundsOncePerRecording() {
        var tracker = HUDCueTracker()
        var state = HUDCueTracker.Snapshot(recording: true)
        _ = tracker.cues(for: state)
        state.inputTrouble = true
        XCTAssertEqual(tracker.cues(for: state), [.trouble])
        state.inputTrouble = false; _ = tracker.cues(for: state)
        state.inputTrouble = true
        XCTAssertEqual(tracker.cues(for: state), [], "a microphone restart must not knock again")
        state = HUDCueTracker.Snapshot(recording: false); _ = tracker.cues(for: state)
        state = HUDCueTracker.Snapshot(recording: true); _ = tracker.cues(for: state)
        state.inputTrouble = true
        XCTAssertEqual(tracker.cues(for: state), [.trouble])
    }

    func testAlyonaCuesFollowMicrophoneMode() {
        var tracker = HUDCueTracker()
        var state = HUDCueTracker.Snapshot(recording: true)
        _ = tracker.cues(for: state)
        state.vik = .finishing
        XCTAssertEqual(tracker.cues(for: state), [], "without headphones the closed note brings the cue")
        state.vik = .speaking; _ = tracker.cues(for: state)
        state.vik = .idle
        XCTAssertEqual(tracker.cues(for: state), [], "without headphones the resumed capture brings the cue")
        state.vik = .failed
        XCTAssertEqual(tracker.cues(for: state), [.fail])

        var phones = HUDCueTracker()
        state = HUDCueTracker.Snapshot(recording: true, headphones: true)
        _ = phones.cues(for: state)
        state.vik = .speaking; _ = phones.cues(for: state)
        state.vik = .idle
        XCTAssertEqual(phones.cues(for: state), [.vikDone])
    }

    func testStartAndStopCues() {
        XCTAssertEqual(HUDCueTracker.startCue(vikResuming: false), .start)
        XCTAssertEqual(HUDCueTracker.startCue(vikResuming: true), .vikDone)
        XCTAssertEqual(HUDCueTracker.stopCue(vik: .idle, headphones: false), .stop)
        XCTAssertEqual(HUDCueTracker.stopCue(vik: .finishing, headphones: false), .vikHeard)
        XCTAssertEqual(HUDCueTracker.stopCue(vik: .finishing, headphones: true), .stop)
    }
}
