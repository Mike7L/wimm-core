import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmiOSApp

@MainActor
final class NoteReprocessingTests: XCTestCase {
    private var directory: URL!
    private var savedHear: String!
    private var savedThink: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        savedHear = Config.transcribeModel
        savedThink = Config.smartModel
        // Distinct ids so the stub can tell the two keys apart.
        ModelSelection.setModel("gemini-test-hear", for: .hear)
        ModelSelection.setModel("vendor/test-think", for: .think)
    }

    override func tearDown() async throws {
        ModelSelection.setModel(savedHear, for: .hear)
        ModelSelection.setModel(savedThink, for: .think)
        try? FileManager.default.removeItem(at: directory)
    }

    private func audioNote(_ name: String = "note.m4a") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data().write(to: url)
        return url
    }

    func testMissingTranscriptionKeyFailsBeforeAnyWork() async throws {
        let url = try audioNote()
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        state.keyedModels = []

        do {
            try await state.retranscribe(url)
            XCTFail("Expected missing key")
        } catch let error as NoteReprocessingError {
            XCTAssertEqual(error, .missingKey(.gemini))
        }
        XCTAssertEqual(state.calls, [])
        XCTAssertTrue(state.reprocessingURLs.isEmpty)
        XCTAssertEqual(state.syncedURLs, [])
    }

    func testRetranscribePublishesAndSyncs() async throws {
        let url = try audioNote()
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)

        try await state.retranscribe(url)
        await state.waitForSync()

        XCTAssertEqual(state.calls, ["transcribe"])
        XCTAssertEqual(state.recordings.map(\.fileURL), [url])
        XCTAssertEqual(state.syncedURLs, [url])
        XCTAssertFalse(state.isReprocessing(url))
    }

    /// "Transcribe again → On-device / Cloud" runs that model for this note
    /// only; the hear model in Settings stays what it was.
    func testTranscribeAgainWithAKindUsesItsModelWithoutChangingSettings() async throws {
        let url = try audioNote()
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        state.keyedModels.insert(ParakeetModel.ultra)

        _ = try await state.perform(.transcribeLocal, url: url)
        _ = try await state.perform(.transcribeCloud, url: url)

        XCTAssertEqual(state.calls, [
            "transcribe:\(ParakeetModel.ultra)",
            "transcribe:gemini-test-hear",
        ])
        XCTAssertEqual(Config.transcribeModel, "gemini-test-hear")
    }

    func testRetranscribeShowsNewTextWithoutACard() async throws {
        let url = try audioNote()
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        state.keyedModels = ["gemini-test-hear"]
        state.transcript = "Новый текст от модели. Дальше."

        try await state.retranscribe(url)

        XCTAssertEqual(state.calls, ["transcribe"])
        XCTAssertEqual(state.recordings.first?.displayTitle, "Новый текст от модели. Дальше.")
        XCTAssertNil(state.recordings.first?.note)
    }

    func testRetranscriptionRejectsTextNotes() async throws {
        let url = directory.appendingPathComponent("typed.txt")
        try "заметка".write(to: url, atomically: true, encoding: .utf8)
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        state.keyedModels = ["vendor/test-think"]

        do {
            try await state.retranscribe(url)
            XCTFail("Text notes have no audio to transcribe")
        } catch let error as NoteReprocessingError {
            XCTAssertEqual(error, .notAudio)
        }
    }

    func testRepublishingAnExistingNoteKeepsItsDayAndPosition() async throws {
        // Crash 2026-10-19 (TestFlight 202610191844): each processed Mac note
        // was re-dated to "now", jumped into Today and back, and the List's
        // UICollectionView aborted with "invalid number of items in section".
        let old = try audioNote("old.m4a")
        let newer = try audioNote("newer.m4a")
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        let lastYear = Date(timeIntervalSince1970: 1_700_000_000)
        state.recordings = [
            Recording(id: "newer.m4a", fileURL: newer, timestamp: Date(), durationSeconds: 3, note: nil),
            Recording(id: "old.m4a", fileURL: old, timestamp: lastYear, durationSeconds: 7, note: nil),
        ]

        await state.publishRecording(at: old)

        XCTAssertEqual(state.recordings.map(\.id), ["newer.m4a", "old.m4a"])
        XCTAssertEqual(state.recordings[1].timestamp, lastYear)
        XCTAssertEqual(state.recordings[1].durationSeconds, 7)
    }

    func testPublishingANewNoteInsertsItInDateOrder() async throws {
        let fresh = try audioNote("fresh.m4a")
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        let lastYear = Date(timeIntervalSince1970: 1_700_000_000)
        state.recordings = [
            Recording(id: "old.m4a", fileURL: directory.appendingPathComponent("old.m4a"), timestamp: lastYear, durationSeconds: 7, note: nil),
        ]

        await state.publishRecording(at: fresh)

        XCTAssertEqual(state.recordings.map(\.id), ["fresh.m4a", "old.m4a"])
    }

    func testProviderErrorIsReducedToItsMessage() {
        let raw = """
        generateContent error: {
          "error": {
            "code": 400,
            "message": "API key not valid. Please pass a valid API key.",
            "status": "INVALID_ARGUMENT"
          }
        }
        """
        XCTAssertEqual(NoteReprocessingError.providerMessage(from: raw), "API key not valid. Please pass a valid API key.")
        XCTAssertEqual(NoteReprocessingError.providerMessage(from: "timed out"), "timed out")
    }

    func testRotatorPlaceholderIsNotAKey() {
        XCTAssertFalse(ConfiguredKeys.containsRealKey(["REPLACE_WITH_YOUR_KEY"]))
        XCTAssertFalse(ConfiguredKeys.containsRealKey(["REPLACE_WITH_OPENROUTER_KEY"]))
        XCTAssertTrue(ConfiguredKeys.containsRealKey(["AIzaSyExampleExampleExample123"]))
    }

    func testSecondTapWhileRunningIsIgnored() async throws {
        let url = try audioNote()
        let state = StubEngineAppState(audioRecorder: ReliableRecorder(), startServices: false)
        state.holdTranscription = true

        let first = Task { try await state.retranscribe(url) }
        await fulfillment(of: [state.transcriptionStarted], timeout: 2)
        XCTAssertTrue(state.isReprocessing(url))
        try await state.retranscribe(url)
        state.releaseTranscription()
        try await first.value

        XCTAssertEqual(state.calls, ["transcribe"])
        XCTAssertFalse(state.isReprocessing(url))
    }
}

@MainActor
private final class StubEngineAppState: AppState {
    var keyedModels: Set<String> = ["gemini-test-hear", "vendor/test-think"]
    var transcript = "Транскрипт"
    var holdTranscription = false
    private(set) var calls: [String] = []
    private(set) var syncedURLs: [URL] = []
    let transcriptionStarted = XCTestExpectation(description: "Transcription started")
    private var transcriptionGate: CheckedContinuation<Void, Never>?
    private var syncWaiters: [CheckedContinuation<Void, Never>] = []

    override func hasKey(for model: String) async -> Bool {
        keyedModels.contains(model)
    }

    override func runTranscription(of url: URL) async throws -> String {
        calls.append("transcribe")
        if holdTranscription { transcriptionStarted.fulfill() }
        if holdTranscription {
            await withCheckedContinuation { transcriptionGate = $0 }
        }
        return storeTranscript(for: url)
    }

    override func runTranscription(of url: URL, model: String) async throws -> String {
        calls.append("transcribe:\(model)")
        return storeTranscript(for: url)
    }

    private func storeTranscript(for url: URL) -> String {
        FileStore.upsertMetadata(for: url, updates: ["transcription": ["transcript": transcript]])
        return transcript
    }

    func releaseTranscription() {
        transcriptionGate?.resume()
        transcriptionGate = nil
    }

    override func enqueueSync(for url: URL) async {
        syncedURLs.append(url)
        syncWaiters.forEach { $0.resume() }
        syncWaiters.removeAll()
    }

    func waitForSync() async {
        guard syncedURLs.isEmpty else { return }
        await withCheckedContinuation { syncWaiters.append($0) }
    }
}
