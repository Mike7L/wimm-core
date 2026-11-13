import XCTest
import WimmDomain
@testable import WimmStudio

final class StudioTextInsertionTests: XCTestCase {
    private func pick(capturing: Bool, live: String, stored: String?, newest: String? = "newest") -> String? {
        StudioTextInsertion.text(isCapturing: capturing, live: live, stored: stored, newest: newest)
    }

    func testRunningRecordingInsertsItsLiveText() {
        XCTAssertEqual(pick(capturing: true, live: " live ", stored: "local"), "live")
    }

    func testStoppedRecordingPrefersTheStoredRunOverTheLiveTextStillOnScreen() {
        XCTAssertEqual(pick(capturing: false, live: "live", stored: " local run "), "local run")
    }

    func testStoppedRecordingFallsBackToLiveTextUntilAUsableRunExists() {
        XCTAssertEqual(pick(capturing: false, live: "live", stored: nil), "live")
        XCTAssertEqual(pick(capturing: false, live: "live", stored: "  "), "live")
        XCTAssertEqual(pick(capturing: false, live: "live", stored: "[[NO_SPEECH]]"), "live")
        XCTAssertEqual(pick(capturing: false, live: "live", stored: "Transcription failed: timeout"), "live")
    }

    func testNoLiveTextInsertsTheNewestNote() {
        XCTAssertEqual(pick(capturing: false, live: "", stored: nil), "newest")
        XCTAssertNil(pick(capturing: false, live: " ", stored: nil, newest: nil))
    }

    private func note(_ name: String, text: String = "Текст", provider: String?) -> Note {
        Note(id: UUID(), index: 0, fileURL: URL(fileURLWithPath: "/tmp/studio-label/\(name)"), fileCreated: Date(),
             start: 0, end: 0, text: text, isFailed: false, transcriptionProvider: provider, hasRaw: false)
    }

    func testAudioNoteSaysWhichTranscriptItsTextIs() {
        XCTAssertEqual(note("a.m4a", provider: nil).studioTranscriptLabel, "живой текст")
        XCTAssertFalse(note("a.m4a", provider: nil).hasFileTranscript)
        XCTAssertEqual(note("a.m4a", provider: "parakeet").studioTranscriptLabel, "локальная")
        XCTAssertTrue(note("a.m4a", provider: "parakeet").hasFileTranscript)
        XCTAssertEqual(note("a.m4a", provider: "gemini").studioTranscriptLabel, "облачная")
        XCTAssertNil(note("a.m4a", text: "", provider: nil).studioTranscriptLabel)
        XCTAssertNil(note("a.txt", provider: nil).studioTranscriptLabel)
    }

    func testClosedNoteCountsAsRunOnlyAfterAFileRunOrNoSpeechVerdict() {
        func landed(_ run: [String: Any]) -> Bool { StudioTextInsertion.fileRunLanded(sidecar: ["transcription": run]) }
        XCTAssertFalse(StudioTextInsertion.fileRunLanded(sidecar: [:]))
        XCTAssertFalse(landed(["transcript": "live", "localTranscript": "live", "speechStatus": "speech"]))
        XCTAssertTrue(landed(["transcript": "local", "localTranscript": "live", "provider": "parakeet"]))
        XCTAssertTrue(landed(["transcript": "live", "localTranscript": "live",
                              "speechStatus": TranscriptionSpeechStatus.noSpeech.rawValue]))
    }

    func testReceiptNamesWhereTheInsertedTextCameFrom() {
        func line(closed: Bool, landed: Bool, live: Bool, reached: Bool = true) -> String {
            StudioTextInsertion.receipt(closedNote: closed, localLanded: landed, hadLive: live, reachedApp: reached)
        }
        XCTAssertEqual(line(closed: true, landed: true, live: true), "Вставлено: локальная расшифровка")
        XCTAssertEqual(line(closed: true, landed: false, live: true), "Вставлено: живой текст (локальная не успела)")
        XCTAssertEqual(line(closed: false, landed: false, live: false), "Вставлено: предыдущая заметка")
        XCTAssertEqual(line(closed: false, landed: false, live: true, reached: false), "В буфере: текст записи — нажмите ⌘V")
    }
}
