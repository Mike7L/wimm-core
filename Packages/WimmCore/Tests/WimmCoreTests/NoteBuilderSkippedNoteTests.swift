import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// Notes the silence gate skipped before transcription must surface as
/// "no speech" (with their probed duration), not as transcription failures.
final class NoteBuilderSkippedNoteTests: XCTestCase {
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

    private func buildNote(for file: URL) async -> Note {
        await NoteBuilder.build(
            file: file,
            index: 0,
            metaRepo: MetadataRepository(),
            transcriptRepo: TranscriptRepository()
        )
    }

    func testStreamingSkippedNoteIsNotFailedAndKeepsDuration() async throws {
        let file = tempDir.appendingPathComponent("skipped.m4a")
        try Data(repeating: 1, count: 16).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "isStreamingSkipped": true,
            "streamingSkipReason": "silent_audio",
            "streamingSkipDurationSec": 2.9,
            "streamingHadConfirmedSpeech": false,
        ])

        let note = await buildNote(for: file)

        XCTAssertFalse(note.isFailed)
        XCTAssertTrue(note.suspectedNoSpeech)
        XCTAssertEqual(note.text, "No speech detected")
        XCTAssertEqual(note.end, 2.9, accuracy: 0.001)
        // Without this the list read the placeholder text as a transcript and
        // showed the skipped recording as "Transcribed".
        XCTAssertEqual(note.transcriptionSpeechStatus, .noSpeech)
    }

    func testSkippedNoteWithLaterTranscriptBehavesAsNormalNote() async throws {
        // A skipped recording re-transcribed afterwards must show its transcript.
        let file = tempDir.appendingPathComponent("retranscribed.m4a")
        try Data(repeating: 1, count: 16).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "isStreamingSkipped": true,
            "streamingSkipReason": "silent_audio",
            "streamingSkipDurationSec": 2.9,
            "transcription": ["transcript": "тихая речь", "audioDurationSec": 3.1],
        ])

        let note = await buildNote(for: file)

        XCTAssertFalse(note.isFailed)
        XCTAssertFalse(note.suspectedNoSpeech)
        XCTAssertEqual(note.text, "тихая речь")
        XCTAssertNil(note.transcriptionSpeechStatus)
        XCTAssertEqual(note.end, 3.1, accuracy: 0.001)
    }

    func testUnskippedFailedNoteStillReportsFailure() async throws {
        let file = tempDir.appendingPathComponent("failed.m4a")
        try Data(repeating: 1, count: 16).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "transcription": ["transcript": "Transcription failed"]
        ])

        let note = await buildNote(for: file)

        XCTAssertTrue(note.isFailed)
        XCTAssertFalse(note.suspectedNoSpeech)
    }

    func testConfirmedNoSpeechIsCompletedAndTyped() async throws {
        let file = tempDir.appendingPathComponent("confirmed-silent.m4a")
        try Data(repeating: 1, count: 16).write(to: file)
        FileStore.upsertMetadata(for: file, updates: [
            "transcription": [
                "provider": "gemini",
                "model": "gemini-test",
                "transcript": "",
                "speechStatus": TranscriptionSpeechStatus.noSpeech.rawValue,
                "audioDurationSec": 7.25,
            ]
        ])

        let note = await buildNote(for: file)

        XCTAssertFalse(note.isFailed)
        XCTAssertEqual(note.transcriptionSpeechStatus, .noSpeech)
        XCTAssertEqual(note.text, "No speech detected")
        XCTAssertEqual(note.end, 7.25, accuracy: 0.001)
        XCTAssertFalse(note.suspectedNoSpeech)

        let info = await MetadataRepository().transcriptionInfo(for: file)
        XCTAssertEqual(info.speechStatus, .noSpeech)
    }
}
