import XCTest
import WimmDomain
import WimmInfrastructure

final class HallucinatedTranscriptClearingTests: XCTestCase {
    private func sidecar(cardEdited: Bool = false) -> [String: Any] {
        var card: [String: Any] = [
            "title": "Sony Inzone M3",
            "summary": "A monitor review.",
            "refined_text": "What else do you need to know about the Sony Inzone M3?",
            "model_used": "gemini-3.5-flash",
            "processed_at": 814_210_649.5,
            "is_liked": true,
            "note_file": "Wimm_2025-08-12_13-49-44.m4a",
        ]
        if cardEdited { card["refined_edited_at"] = 814_210_700.0 }
        return [
            "recordingId": "R1",
            "syncId": "S1",
            "analysisGlossary": ["version": "x"],
            "noteCard": card,
            "transcription": [
                "transcript": "What else do you need to know about the Sony Inzone M3? Well, for one…",
                "speechStatus": "speech",
                "model": "gemini-3-flash-preview",
                "audioDurationSec": 1.88,
                "raw": "{}",
                "localTranscript": "",
            ],
        ]
    }

    func testClearsToTheNoSpeechShape() throws {
        var meta = sidecar()
        let outcome = HallucinatedTranscriptClearing.clear(&meta, reason: "confirmed_no_speech")
        XCTAssertEqual(outcome, .cleared(previousWords: 15))

        let t = try XCTUnwrap(meta["transcription"] as? [String: Any])
        XCTAssertEqual(t["transcript"] as? String, "")
        XCTAssertEqual(t["speechStatus"] as? String, TranscriptionSpeechStatus.noSpeech.rawValue)
        XCTAssertNil(t["raw"])
        XCTAssertEqual(t["audioDurationSec"] as? Double, 1.88, "duration still describes the file")
        XCTAssertEqual(t["hallucinationClearReason"] as? String, "confirmed_no_speech")

        let card = try XCTUnwrap(meta["noteCard"] as? [String: Any])
        XCTAssertEqual(card["title"] as? String, "")
        XCTAssertEqual(card["summary"] as? String, "No speech detected")
        XCTAssertNil(card["refined_text"])
        XCTAssertNil(card["processed_at"])
        XCTAssertEqual(card["is_liked"] as? Bool, true, "user flags survive")

        XCTAssertNil(meta["analysisGlossary"])
        XCTAssertEqual(meta["suspectedNoSpeech"] as? Bool, true)
        XCTAssertEqual(meta["recordingId"] as? String, "R1")
        XCTAssertEqual(meta["syncId"] as? String, "S1")
    }

    func testUserEditedCardIsLeftAlone() {
        var meta = sidecar(cardEdited: true)
        let before = NSDictionary(dictionary: meta)
        XCTAssertEqual(HallucinatedTranscriptClearing.clear(&meta, reason: "x"), .skippedUserEdited)
        XCTAssertEqual(NSDictionary(dictionary: meta), before)
    }

    func testNullEditMarkIsNotAnEdit() {
        var meta = sidecar()
        var card = meta["noteCard"] as! [String: Any]
        card["refined_edited_at"] = NSNull()
        meta["noteCard"] = card
        XCTAssertEqual(HallucinatedTranscriptClearing.clear(&meta, reason: "x"), .cleared(previousWords: 15))
    }

    func testAlreadyEmptyIsANoOp() {
        var meta: [String: Any] = ["transcription": ["transcript": "  ", "speechStatus": "no_speech"]]
        XCTAssertEqual(HallucinatedTranscriptClearing.clear(&meta, reason: "x"), .skippedAlreadyEmpty)
    }

    func testClearedNoteBuildsAsNoSpeech() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClearNoSpeech_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("Wimm_2025-08-12_13-49-44.m4a")
        try Data([0]).write(to: audio)
        var meta = sidecar()
        _ = HallucinatedTranscriptClearing.clear(&meta, reason: "confirmed_no_speech")
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) { current in
            current = meta
            return true
        }
        let note = await NoteBuilder.build(
            file: audio, index: 0,
            metaRepo: MetadataRepository(), transcriptRepo: TranscriptRepository()
        )
        XCTAssertEqual(note.text, "No speech detected")
        XCTAssertFalse(note.isFailed)
        XCTAssertTrue(note.suspectedNoSpeech)
    }
}
