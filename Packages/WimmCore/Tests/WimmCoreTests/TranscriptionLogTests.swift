import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// `recordRunSuccess` must never let an empty (re-)transcription
/// overwrite a transcript that was already captured. A note transcribed once to
/// real text, then re-run later and returning "" (e.g. [[NO_SPEECH]] on quiet
/// audio), used to lose its stored transcript and fall out of audit coverage.
final class TranscriptionLogTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }

    override func tearDown() {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func storedTranscript(for file: URL) -> String? {
        storedTranscription(for: file)["transcript"] as? String
    }

    private func storedMetadata(for file: URL) -> [String: Any] {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private func storedTranscription(for file: URL) -> [String: Any] {
        storedMetadata(for: file)["transcription"] as? [String: Any] ?? [:]
    }

    func testRunSuccessWriterFieldsAreExplicitlyClassified() {
        XCTAssertEqual(
            transcriptionFieldsWrittenByRunSuccess,
            transcriptionRunScopedKeys.union(transcriptionContentKeys)
        )
        XCTAssertTrue(
            transcriptionRunScopedKeys.isDisjoint(with: transcriptionContentKeys),
            "A field cannot have both run-scoped and content lifecycle semantics"
        )
    }

    func testRunSuccessPreservesDurableAndUnknownFieldsButResetsOldRun() throws {
        let file = tempDir.appendingPathComponent("classified.m4a")
        try Data().write(to: file)
        FileStore.upsertTranscriptionFields(
            for: file,
            updates: [
                "localTranscript": "device hypothesis",
                "extensionSentinel": "keep me",
                "provider": "old provider",
                "model": "old model",
                "startedAt": "old start",
                "elapsedMs": 999,
                "raw": "old raw",
                "agentRecommendation": "old recommendation",
                "agentReason": "old reason",
                "transcript": "old transcript",
                "audioDurationSec": 999.0,
                "speakerTurns": ["speakers": 2, "turns": [["speaker": 1, "text": "old transcript"]]],
            ]
        )

        recordRunSuccess(
            file: file, provider: "gemini", model: "new model",
            audioDuration: nil, startedAt: Date(), elapsedSeconds: 0.25,
            transcript: "new transcript", speechStatus: .speech, rawResponse: nil
        )

        let transcription = storedTranscription(for: file)
        XCTAssertEqual(transcription["localTranscript"] as? String, "device hypothesis")
        XCTAssertEqual(transcription["extensionSentinel"] as? String, "keep me")
        XCTAssertEqual(transcription["provider"] as? String, "gemini")
        XCTAssertEqual(transcription["model"] as? String, "new model")
        XCTAssertEqual(transcription["transcript"] as? String, "new transcript")
        XCTAssertNil(transcription["raw"])
        XCTAssertNil(transcription["agentRecommendation"])
        XCTAssertNil(transcription["agentReason"])
        XCTAssertNil(transcription["audioDurationSec"])
        XCTAssertNil(transcription["speakerTurns"], "a speaker split of the replaced text must not survive")
        XCTAssertNotEqual(transcription["startedAt"] as? String, "old start")
        XCTAssertEqual(transcription["elapsedMs"] as? Int, 250)
    }

    func testRunSuccessStoresDurationAndClearsFailuresInSameOperation() throws {
        let file = tempDir.appendingPathComponent("duration.m4a")
        try Data().write(to: file)
        FileStore.upsertMetadata(
            for: file,
            updates: [
                "transcriptionFailure": "old failure",
                "transcriptionFailureDetails": ["reason": "old"],
            ]
        )

        recordRunSuccess(
            file: file, provider: "vision", model: "PDFKit",
            audioDuration: 42.75, startedAt: Date(), elapsedSeconds: 0.1,
            transcript: "document text", speechStatus: .speech, rawResponse: nil
        )

        let metadata = storedMetadata(for: file)
        let transcription = storedTranscription(for: file)
        XCTAssertEqual(transcription["audioDurationSec"] as? Double, 42.75)
        XCTAssertNil(metadata["transcriptionFailure"])
        XCTAssertNil(metadata["transcriptionFailureDetails"])
    }

    func testEmptyRetranscriptionLeavesFailureMarkersIntact() throws {
        let file = tempDir.appendingPathComponent("suspicious-empty.m4a")
        try Data().write(to: file)
        FileStore.upsertMetadata(
            for: file,
            updates: [
                "transcription": ["transcript": "existing text"],
                "transcriptionFailure": "retry failed",
            ]
        )

        recordRunSuccess(
            file: file, provider: "gemini", model: "model",
            audioDuration: 4, startedAt: Date(), elapsedSeconds: 0.1,
            transcript: "  \n", speechStatus: .noSpeech, rawResponse: nil
        )

        XCTAssertEqual(storedTranscript(for: file), "existing text")
        XCTAssertEqual(storedMetadata(for: file)["transcriptionFailure"] as? String, "retry failed")
    }

    func testConcurrentNestedMutationsDoNotLoseFields() throws {
        let file = tempDir.appendingPathComponent("concurrent.m4a")
        try Data().write(to: file)
        let count = 64

        DispatchQueue.concurrentPerform(iterations: count) { index in
            FileStore.upsertTranscriptionFields(
                for: file,
                updates: ["extension-\(index)": index]
            )
        }

        let transcription = storedTranscription(for: file)
        for index in 0..<count {
            XCTAssertEqual(transcription["extension-\(index)"] as? Int, index)
        }
    }

    func testEmptyRetranscriptionDoesNotClobberExistingTranscript() throws {
        let file = tempDir.appendingPathComponent("note.m4a")
        try Data(repeating: 1, count: 16).write(to: file)

        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-2.5-flash",
            audioDuration: 30, startedAt: Date(), elapsedSeconds: 2,
            transcript: "It's so early. I am very tired.",
            speechStatus: .speech, rawResponse: nil
        )
        XCTAssertEqual(storedTranscript(for: file), "It's so early. I am very tired.")

        // A later empty re-run (NO_SPEECH → "") must be ignored.
        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-2.5-flash",
            audioDuration: 30, startedAt: Date(), elapsedSeconds: 1,
            transcript: "", speechStatus: .noSpeech, rawResponse: nil
        )
        XCTAssertEqual(storedTranscript(for: file), "It's so early. I am very tired.",
                       "empty re-transcription overwrote a non-empty transcript")

        // Whitespace-only is treated as empty too.
        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-2.5-flash",
            audioDuration: 30, startedAt: Date(), elapsedSeconds: 1,
            transcript: "   \n ", speechStatus: .noSpeech, rawResponse: nil
        )
        XCTAssertEqual(storedTranscript(for: file), "It's so early. I am very tired.")
    }

    func testEmptyFirstTranscriptionIsStillRecorded() throws {
        // No prior transcript → an empty result (genuine silence) is recorded as
        // "" so the note still carries transcription metadata.
        let file = tempDir.appendingPathComponent("silent.m4a")
        try Data(repeating: 1, count: 16).write(to: file)

        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-2.5-flash",
            audioDuration: 5, startedAt: Date(), elapsedSeconds: 1,
            transcript: "", speechStatus: .noSpeech, rawResponse: nil
        )
        XCTAssertEqual(storedTranscript(for: file), "")
        XCTAssertEqual(
            storedTranscription(for: file)["speechStatus"] as? String,
            TranscriptionSpeechStatus.noSpeech.rawValue
        )
    }

    func testNonEmptyRetranscriptionStillOverwrites() throws {
        let file = tempDir.appendingPathComponent("corrected.m4a")
        try Data(repeating: 1, count: 16).write(to: file)

        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-2.5-flash",
            audioDuration: 10, startedAt: Date(), elapsedSeconds: 1,
            transcript: "first pass", speechStatus: .speech, rawResponse: nil
        )
        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-2.5-flash",
            audioDuration: 10, startedAt: Date(), elapsedSeconds: 1,
            transcript: "second, better pass", speechStatus: .speech, rawResponse: nil
        )
        XCTAssertEqual(storedTranscript(for: file), "second, better pass")
    }

    /// An `_Attach_` file resolves to its parent's sidecar, so transcribing an
    /// audio attachment used to overwrite the note's main transcript with the
    /// attachment's text (and a failed attachment marked the note failed).
    /// Found 2026-10-05 via RealNotesPipelineRegressionTests, which had been
    /// red since it was written.
    func testAttachmentTranscriptionDoesNotTouchParentTranscript() throws {
        let note = tempDir.appendingPathComponent("Wimm_2026-02-09_15-51-51.m4a")
        let attachment = tempDir.appendingPathComponent("Wimm_2026-02-09_15-51-51_Attach_voice.opus")
        try Data().write(to: note)
        try Data().write(to: attachment)

        recordRunSuccess(
            file: note, provider: "test", model: "m", audioDuration: 1,
            startedAt: Date(), elapsedSeconds: 0, transcript: "main note text",
            speechStatus: .speech, rawResponse: nil
        )
        recordRunSuccess(
            file: attachment, provider: "test", model: "m", audioDuration: 1,
            startedAt: Date(), elapsedSeconds: 0, transcript: "attachment text",
            speechStatus: .speech, rawResponse: nil
        )
        persistTranscriptionFailure(file: attachment, reason: .network, underlying: nil)

        XCTAssertEqual(storedTranscript(for: note), "main note text")
        XCTAssertNil(storedMetadata(for: note)["transcriptionFailure"])
    }

    func testRunSuccessPersistsAndArchivesConfidenceAndQuality() throws {
        let file = tempDir.appendingPathComponent("quality.m4a")
        try Data().write(to: file)
        let timed = (0..<10).map { i in
            SpeakerTurns.Word(text: "слово\(i)", start: Double(i), end: Double(i) + 0.5, confidence: i < 4 ? 0.45 : 0.90)
        }

        recordRunSuccess(
            file: file, provider: "parakeet", model: "ultra",
            audioDuration: 20, startedAt: Date(), elapsedSeconds: 0.3,
            transcript: timed.map(\.text).joined(separator: " "),
            speechStatus: .speech, rawResponse: nil,
            confidence: 0.78, timedWords: timed
        )

        let first = storedTranscription(for: file)
        XCTAssertEqual((first["confidence"] as? NSNumber)?.doubleValue ?? 0, 0.78, accuracy: 0.001)
        let firstQuality = try XCTUnwrap(first["quality"] as? [String: Any])
        XCTAssertEqual(firstQuality["status"] as? String, "suspect")
        XCTAssertEqual(firstQuality["issues"] as? [String], ["confidence:low_word_confidence"])
        XCTAssertEqual((firstQuality["p10Confidence"] as? NSNumber)?.doubleValue ?? 0, 0.45, accuracy: 0.001)
        XCTAssertEqual((firstQuality["lowConfidenceWordShare"] as? NSNumber)?.doubleValue ?? 0, 0.40, accuracy: 0.001)

        // A cloud re-run archives the Parakeet confidence & quality in `previousRuns`
        // and replaces the current `quality` with the cloud run's own report.
        recordRunSuccess(
            file: file, provider: "gemini", model: "gemini-3-flash-preview",
            audioDuration: 20, startedAt: Date(), elapsedSeconds: 1.2,
            transcript: "чистый облачный транскрипт без повторов",
            speechStatus: .speech, rawResponse: nil
        )

        let second = storedTranscription(for: file)
        XCTAssertNil(second["confidence"], "cloud run has no Parakeet confidence")
        let secondQuality = try XCTUnwrap(second["quality"] as? [String: Any])
        XCTAssertEqual(secondQuality["status"] as? String, "unknown")
        XCTAssertEqual((secondQuality["checks"] as? [String: String])?["confidence"], "unavailable")
        XCTAssertEqual(secondQuality["issues"] as? [String], [])

        let archived = try XCTUnwrap((second["previousRuns"] as? [[String: Any]])?.first)
        XCTAssertEqual((archived["confidence"] as? NSNumber)?.doubleValue ?? 0, 0.78, accuracy: 0.001)
        let archivedQuality = try XCTUnwrap(archived["quality"] as? [String: Any])
        XCTAssertEqual(archivedQuality["issues"] as? [String], ["confidence:low_word_confidence"])
    }
}
