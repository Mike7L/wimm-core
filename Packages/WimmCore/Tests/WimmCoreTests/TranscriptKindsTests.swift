import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// Realtime, on-device and cloud transcripts of one note live side by side
/// and none of them destroys another (`TranscriptKind`).
final class TranscriptKindsTests: XCTestCase {
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

    private var noteFile: URL { tempDir.appendingPathComponent("Wimm_2026-10-24_10-00-00_KIND.m4a") }

    private func run(_ provider: String, _ model: String, _ text: String) {
        recordRunSuccess(file: noteFile, provider: provider, model: model, audioDuration: 4,
                         startedAt: Date(), elapsedSeconds: 1, transcript: text,
                         speechStatus: .speech, rawResponse: nil)
    }

    private func sidecar() throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: noteFile))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testProvidersAndModelsClassify() {
        XCTAssertEqual(TranscriptKind.ofProvider("parakeet"), .local)
        XCTAssertEqual(TranscriptKind.ofProvider("whisperkit"), .local)
        XCTAssertEqual(TranscriptKind.ofProvider("native"), .local)
        XCTAssertEqual(TranscriptKind.ofProvider("gemini"), .cloud)
        XCTAssertEqual(TranscriptKind.ofProvider("openrouter"), .cloud)
        XCTAssertNil(TranscriptKind.ofProvider("test"))
        XCTAssertNil(TranscriptKind.ofProvider(nil))

        XCTAssertEqual(TranscriptKind.ofModel(ParakeetModel.ultra), .local)
        XCTAssertEqual(TranscriptKind.ofModel("whisper:large-v3"), .local)
        XCTAssertEqual(TranscriptKind.ofModel("gemini-3-flash-preview"), .cloud)
        XCTAssertEqual(TranscriptKind.ofModel("openai/gpt-4o-mini-transcribe"), .cloud)
    }

    func testRetranscriptionModelNeverPicksParakeetForTheCloud() {
        XCTAssertEqual(TranscriptKind.local.retranscriptionModel(configured: "gemini-3-flash-preview"),
                       ParakeetModel.ultra)
        XCTAssertEqual(TranscriptKind.cloud.retranscriptionModel(configured: "gemini-3-flash-preview"),
                       "gemini-3-flash-preview")
        // ModelRouter files Parakeet under Gemini; the cloud choice must not.
        XCTAssertEqual(TranscriptKind.cloud.retranscriptionModel(configured: ParakeetModel.ultra),
                       ModelSelection.defaultGeminiModel)
        XCTAssertNil(TranscriptKind.realtime.retranscriptionModel())
    }

    func testLatestLocalAndCloudRunsAreBothAddressable() throws {
        try Data().write(to: noteFile)
        FileStore.upsertTranscriptionFields(for: noteFile, updates: ["localTranscript": "live"])
        run("parakeet", "ultra", "parakeet text")
        run("gemini", "gemini-3-flash-preview", "cloud text")

        let transcription = try XCTUnwrap(TranscriptRuns.transcription(fromSidecar: try sidecar()))
        XCTAssertEqual(TranscriptRuns.realtime(in: transcription), "live")
        let local = try XCTUnwrap(TranscriptRuns.latest(.local, in: transcription))
        XCTAssertEqual(local.text, "parakeet text")
        XCTAssertFalse(local.isCurrent)
        let cloud = try XCTUnwrap(TranscriptRuns.latest(.cloud, in: transcription))
        XCTAssertEqual(cloud.text, "cloud text")
        XCTAssertTrue(cloud.isCurrent)

        let variants = NoteTranscriptVariant.variants(forNoteFile: noteFile)
        XCTAssertEqual(variants.map(\.kind), [.realtime, .local, .cloud])
        XCTAssertEqual(variants.map(\.isCurrentRun), [false, false, true])
        XCTAssertEqual(variants[1].provider, "parakeet")

        // get_note prints the run the current one replaced.
        let other = RecallSidecar(try sidecar()).otherRuns
        XCTAssertEqual(other.map(\.text), ["parakeet text"])
    }

    func testManyCloudRerunsNeverEvictTheOnlyLocalRun() throws {
        try Data().write(to: noteFile)
        run("parakeet", "ultra", "the only parakeet text")
        for i in 0..<(transcriptionPreviousRunsLimit + 4) {
            run("gemini", "flash", "cloud take \(i)")
        }
        let transcription = try XCTUnwrap(TranscriptRuns.transcription(fromSidecar: try sidecar()))
        let archived = transcription[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
        XCTAssertEqual(archived.count, transcriptionPreviousRunsLimit)
        XCTAssertEqual(TranscriptRuns.latest(.local, in: transcription)?.text, "the only parakeet text")
        XCTAssertEqual(TranscriptRuns.latest(.cloud, in: transcription)?.text,
                       "cloud take \(transcriptionPreviousRunsLimit + 3)")
        // The oldest cloud takes went first.
        XCTAssertFalse(archived.contains { $0["transcript"] as? String == "cloud take 0" })
    }

    /// The iPhone recorder writes `transcription` as a plain string — its live
    /// text. A file run used to replace that string with a dictionary and the
    /// live text was gone.
    func testFileRunKeepsTheIPhoneLiveStringAsRealtime() async throws {
        try Data().write(to: noteFile)
        let sidecarURL = FileStore.metadataURL(forRecordingURL: noteFile)
        let legacy: [String: Any] = ["transcription": "живой текст с айфона", "isComplete": true]
        try JSONSerialization.data(withJSONObject: legacy).write(to: sidecarURL)

        // Before any run the string is the transcript and not a second hypothesis.
        let repo = TranscriptRepository()
        let before = await repo.localTranscriptText(for: noteFile)
        XCTAssertNil(before)
        XCTAssertEqual(NoteTranscriptVariant.variants(forNoteFile: noteFile).map(\.kind), [.realtime])

        run("gemini", "gemini-3-flash-preview", "облачный текст")

        let transcription = try XCTUnwrap(try sidecar()["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["transcript"] as? String, "облачный текст")
        XCTAssertEqual(transcription["localTranscript"] as? String, "живой текст с айфона")
        // The live copy is not archived as if it were a run.
        XCTAssertNil(transcription[transcriptionPreviousRunsKey])
        let after = await repo.localTranscriptText(for: noteFile)
        XCTAssertEqual(after, "живой текст с айфона")
        let variants = NoteTranscriptVariant.variants(forNoteFile: noteFile)
        XCTAssertEqual(variants.map(\.kind), [.realtime, .cloud])
    }

    func testRecorderSaveDoesNotReplaceATranscriptionDictionary() throws {
        try Data().write(to: noteFile)
        var metadata = RecordingMetadata(recordingURL: noteFile, transcription: "live", duration: 4,
                                         timestamp: Date(), isComplete: false, lastSaved: Date())
        try metadata.save()
        run("parakeet", "ultra", "parakeet text")

        metadata.isComplete = true
        try metadata.save()

        let stored = try sidecar()
        let transcription = try XCTUnwrap(stored["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["transcript"] as? String, "parakeet text")
        XCTAssertEqual(transcription["localTranscript"] as? String, "live")
        XCTAssertEqual(stored["isComplete"] as? Bool, true)
        // And the dictionary form still loads.
        XCTAssertEqual(try RecordingMetadata.load(for: noteFile).transcription, "parakeet text")
    }

    func testSuccessfulRunIsRecognizedSoAFailedRerunKeepsTheText() async throws {
        try Data().write(to: noteFile)
        XCTAssertFalse(TranscriptRuns.hasSuccessfulRun(forNoteFile: noteFile))
        run("gemini", "flash", "good text")
        XCTAssertTrue(TranscriptRuns.hasSuccessfulRun(forNoteFile: noteFile))

        let repo = TranscriptRepository()
        _ = await repo.recordTranscriptionFailure(for: noteFile, reason: .network, underlying: nil)
        await repo.writeFailurePlaceholder(duration: 4, file: noteFile, reasonLabel: "network")
        XCTAssertFalse(TranscriptRuns.hasSuccessfulRun(forNoteFile: noteFile),
                       "a placeholder is not a run")
    }
}
