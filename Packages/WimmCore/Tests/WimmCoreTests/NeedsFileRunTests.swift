import XCTest
import WimmDomain
import WimmInfrastructure

/// One rule for every device: live text alone is not a file run
/// (`TranscriptRuns.needsFileRun`).
final class NeedsFileRunTests: XCTestCase {
    private let audio = URL(fileURLWithPath: "/tmp/Wimm_2026-11-03_15-39-38_7F0604AC.m4a")

    private func needs(_ meta: [String: Any], file: URL? = nil) -> Bool {
        TranscriptRuns.needsFileRun(file: file ?? audio, sidecar: meta)
    }

    func testRecordingWithOnlyIdentityNeedsRun() {
        XCTAssertTrue(needs(["recordingId": "7F0604AC"]))
    }

    func testEmptyTextNeedsRun() {
        XCTAssertTrue(needs(["transcription": ["transcript": "  "]]))
        XCTAssertTrue(needs(["transcription": ""]))
    }

    func testLiveTextAloneNeedsRunOnEveryDevice() {
        // An old iPhone's plain string and the dictionary every device writes now.
        XCTAssertTrue(needs(["transcription": "Привет с iPhone"]))
        XCTAssertTrue(needs(["transcription": [
            "transcript": "Привет", "localTranscript": "Привет",
            "speechStatus": TranscriptionSpeechStatus.speech.rawValue]]))
    }

    func testFileRunIsDone() {
        XCTAssertFalse(needs(["transcription": [
            "transcript": "Привет, это файл", "localTranscript": "Привет", "provider": "parakeet"]]))
        XCTAssertFalse(needs(["transcription": [
            "transcript": "Привет", "localTranscript": "Привет", "provider": "parakeet"]]))
        XCTAssertFalse(needs(["transcription": ["transcript": "Привет"]]))
    }

    func testNoSpeechAndTapsAreDone() {
        XCTAssertFalse(needs(["transcription": ["speechStatus": TranscriptionSpeechStatus.noSpeech.rawValue]]))
        XCTAssertFalse(needs(["duration": 0.4]))
    }

    func testDerivedAndNonAudioFilesAreSkipped() {
        XCTAssertFalse(needs([:], file: URL(fileURLWithPath: "/tmp/Wimm_2026-11-03_15-39-38_7F0604AC_micro.m4a")))
        XCTAssertFalse(needs([:], file: URL(fileURLWithPath: "/tmp/note.txt")))
    }
}
