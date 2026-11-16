import XCTest
@testable import WimmStudio

final class MicToggleTests: XCTestCase {
    private func mode(_ change: (inout MicToggleMode.Input) -> Void) -> MicToggleMode {
        var input = MicToggleMode.Input()
        change(&input)
        return MicToggleMode.resolve(input)
    }

    func testCaptureStatesFromOffToSpeech() {
        XCTAssertEqual(mode { _ in }, .off)
        XCTAssertEqual(mode { $0.isBusy = true }, .busy)
        XCTAssertEqual(mode { $0.isRecording = true }, .quiet)
        XCTAssertEqual(mode { $0.isRecording = true; $0.level = 0.05 }, .quiet)
        XCTAssertEqual(mode { $0.isRecording = true; $0.level = 0.4 }, .sound)
        XCTAssertEqual(mode { $0.isRecording = true; $0.level = 0.4; $0.isSpeech = true }, .speech)
    }

    func testSpeechAndLevelNeverShowWhileNotRecording() {
        XCTAssertEqual(mode { $0.level = 0.9; $0.isSpeech = true }, .off)
    }

    func testInputTroubleWinsOverSoundAndSpeech() {
        XCTAssertEqual(mode { $0.isRecording = true; $0.inputTrouble = true; $0.isSpeech = true; $0.level = 0.8 },
                       .trouble)
        XCTAssertEqual(mode { $0.isRecording = true; $0.inputTrouble = true; $0.vik = .listening }, .trouble)
    }

    func testVikStates() {
        XCTAssertEqual(mode { $0.isRecording = true; $0.vik = .listening }, .vikListening)
        XCTAssertEqual(mode { $0.vik = .finishing; $0.isBusy = true }, .vikThinking(micOpen: false))
        XCTAssertEqual(mode { $0.vik = .thinking }, .vikThinking(micOpen: false))
        XCTAssertEqual(mode { $0.vik = .speaking }, .vikSpeaking(micOpen: false))
        // Headphones mode: the microphone stays open through the answer.
        XCTAssertEqual(mode { $0.vik = .speaking; $0.isRecording = true; $0.vikKeepsMicOpen = true },
                       .vikSpeaking(micOpen: true))
        // The setting alone does not open the microphone.
        XCTAssertEqual(mode { $0.vik = .speaking; $0.vikKeepsMicOpen = true }, .vikSpeaking(micOpen: false))
    }

    func testFailedVikFallsBackToCaptureState() {
        XCTAssertEqual(mode { $0.vik = .failed }, .off)
        XCTAssertEqual(mode { $0.vik = .failed; $0.isRecording = true; $0.isSpeech = true }, .speech)
    }

    func testCountdownStaysHiddenForShortPauses() {
        XCTAssertNil(MicToggleCountdown.make(quietSeconds: 0.5, totalSeconds: 10))
        XCTAssertNil(MicToggleCountdown.make(quietSeconds: 3, totalSeconds: 10))
        let early = try? XCTUnwrap(MicToggleCountdown.make(quietSeconds: 3.3, totalSeconds: 10))
        XCTAssertEqual(early?.opacity ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(early?.length ?? 0, 0.67, accuracy: 0.001)
    }

    func testCountdownRunsOutAtTheSplit() {
        let late = MicToggleCountdown.make(quietSeconds: 9, totalSeconds: 10)
        XCTAssertEqual(late?.opacity, 1)
        XCTAssertEqual(late?.length ?? 0, 0.1, accuracy: 0.001)
        XCTAssertNil(MicToggleCountdown.make(quietSeconds: 10, totalSeconds: 10))
        XCTAssertNil(MicToggleCountdown.make(quietSeconds: 2, totalSeconds: 0))
    }

    func testCountdownScalesItsHiddenPartForShortSplits() {
        // A 4 s split hides 1.2 s, not 3 of its 4 seconds.
        XCTAssertNil(MicToggleCountdown.make(quietSeconds: 1.2, totalSeconds: 4))
        XCTAssertNotNil(MicToggleCountdown.make(quietSeconds: 1.5, totalSeconds: 4))
    }
}
