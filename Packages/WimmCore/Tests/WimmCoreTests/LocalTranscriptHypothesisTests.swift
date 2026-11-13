import XCTest
import WimmDomain
import WimmInfrastructure

/// The on-device hypothesis is written at recording finalization, while the
/// cloud transcript lands later through a different writer. These tests pin the
/// contract that makes the two-hypothesis refine possible: the later write must
/// not drop the earlier one.
final class LocalTranscriptHypothesisTests: XCTestCase {

    private var recording: URL!

    override func setUpWithError() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local-hypothesis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        recording = dir.appendingPathComponent("rec.m4a")
        try Data().write(to: recording)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: recording.deletingLastPathComponent())
    }

    private func transcriptionDict() throws -> [String: Any] {
        let metaURL = FileStore.metadataURL(forRecordingURL: recording)
        let data = try Data(contentsOf: metaURL)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(json["transcription"] as? [String: Any])
    }

    func testUpsertTranscriptionFieldsKeepsExistingKeys() throws {
        FileStore.upsertTranscriptionFields(
            for: recording, updates: ["transcript": "cloud text", "provider": "gemini"])
        FileStore.upsertTranscriptionFields(
            for: recording, updates: ["localTranscript": "local text"])

        let transcription = try transcriptionDict()
        XCTAssertEqual(transcription["transcript"] as? String, "cloud text")
        XCTAssertEqual(transcription["provider"] as? String, "gemini")
        XCTAssertEqual(transcription["localTranscript"] as? String, "local text")
    }

    /// The load-bearing case: finalization stores the local hypothesis, then the
    /// cloud transcript arrives. Before this contract existed the local text was
    /// simply discarded, which is what made the second hypothesis unavailable.
    func testCloudTranscriptWritePreservesLocalHypothesis() async throws {
        FileStore.upsertTranscriptionFields(
            for: recording, updates: ["localTranscript": "в хад нужна кнопка записи"])

        let repo = TranscriptRepository()
        try await repo.updateTranscriptText(
            text: "в HUD нужна кнопка записи", duration: 12.5, to: recording)

        let transcription = try transcriptionDict()
        XCTAssertEqual(transcription["transcript"] as? String, "в HUD нужна кнопка записи")
        XCTAssertEqual(
            transcription["localTranscript"] as? String, "в хад нужна кнопка записи",
            "Cloud transcript write must not drop the on-device hypothesis")

        let readBack = await repo.localTranscriptText(for: recording)
        XCTAssertEqual(readBack, "в хад нужна кнопка записи")
    }

    /// The path the GUI actually takes. `recordRunSuccess` rebuilds
    /// the transcription dict from scratch and replaces it wholesale, so it
    /// silently dropped the hypothesis even though the other writer merged
    /// correctly — the first live recording came back without the field.
    func testRecordRunSuccessPreservesLocalHypothesis() throws {
        FileStore.upsertTranscriptionFields(
            for: recording, updates: ["localTranscript": "в хад нужна кнопка записи"])

        recordRunSuccess(
            file: recording,
            provider: "gemini",
            model: "gemini-2.5-flash",
            audioDuration: 12.5,
            startedAt: Date(),
            elapsedSeconds: 1.2,
            transcript: "в HUD нужна кнопка записи",
            speechStatus: .speech,
            rawResponse: nil
        )

        let transcription = try transcriptionDict()
        XCTAssertEqual(transcription["transcript"] as? String, "в HUD нужна кнопка записи")
        XCTAssertEqual(transcription["provider"] as? String, "gemini")
        XCTAssertEqual(
            transcription["localTranscript"] as? String, "в хад нужна кнопка записи",
            "The cloud transcription write must carry the on-device hypothesis over")
    }

    /// Re-transcribing must not resurrect stale run-scoped keys, which is why
    /// the dict is replaced rather than merged.
    func testRecordRunSuccessStillDropsStaleRunKeys() throws {
        FileStore.upsertTranscriptionFields(
            for: recording, updates: ["raw": "old raw payload", "localTranscript": "local"])

        recordRunSuccess(
            file: recording, provider: "gemini", model: "m", audioDuration: 1,
            startedAt: Date(), elapsedSeconds: 0.1, transcript: "fresh",
            speechStatus: .speech, rawResponse: nil)

        let transcription = try transcriptionDict()
        XCTAssertNil(transcription["raw"], "Stale raw from a previous run must not survive")
        XCTAssertEqual(transcription["localTranscript"] as? String, "local")
    }

    func testLocalTranscriptTextIsNilWhenAbsentOrBlank() async throws {
        let repo = TranscriptRepository()
        var absent = await repo.localTranscriptText(for: recording)
        XCTAssertNil(absent, "Imports and file-based notes have no local hypothesis")

        FileStore.upsertTranscriptionFields(for: recording, updates: ["localTranscript": "   "])
        absent = await repo.localTranscriptText(for: recording)
        XCTAssertNil(absent, "Whitespace-only hypothesis must not reach the refine prompt")
    }
}
