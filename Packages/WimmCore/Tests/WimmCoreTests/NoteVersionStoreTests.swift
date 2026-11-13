import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class NoteVersionStoreTests: XCTestCase {
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

    private var noteFile: URL { tempDir.appendingPathComponent("Wimm_2026-10-24_10-00-00_AAAA.m4a") }

    func testFirstEditKeepsTheTextItReplaced() async {
        let store = NoteVersionStore(directory: tempDir.appendingPathComponent("NoteHistory"))
        let history = await store.record(previous: "model text", new: "my text", source: .manual, for: noteFile)
        XCTAssertEqual(history.map(\.text), ["model text", "my text"])
        XCTAssertEqual(history.map(\.source), [.baseline, .manual])
    }

    func testAutosavesInsideTheWindowExtendOneVersion() async {
        let store = NoteVersionStore(directory: tempDir.appendingPathComponent("NoteHistory"))
        let start = Date()
        await store.record(previous: "a", new: "ab", source: .manual, for: noteFile, now: start)
        await store.record(previous: "ab", new: "abc", source: .manual, for: noteFile, now: start + 1)
        let later = await store.record(previous: "abc", new: "abcd", source: .manual, for: noteFile,
                                       now: start + NoteVersionStore.coalesceWindow + 10)
        XCTAssertEqual(later.map(\.text), ["a", "abc", "abcd"])
    }

    func testRestoreIsItsOwnVersionAndOutsideChangesBecomeBaselines() async {
        let store = NoteVersionStore(directory: tempDir.appendingPathComponent("NoteHistory"))
        await store.record(previous: "v1", new: "v2", source: .manual, for: noteFile)
        // Re-analysis replaced the body with "v3" behind the editor's back.
        let history = await store.record(previous: "v3", new: "v1", source: .restored, for: noteFile)
        XCTAssertEqual(history.map(\.text), ["v1", "v2", "v3", "v1"])
        XCTAssertEqual(history.last?.source, .restored)

        let reloaded = await NoteVersionStore(directory: tempDir.appendingPathComponent("NoteHistory"))
            .versions(for: noteFile)
        // ISO-8601 on disk keeps whole seconds; content and order are what matter.
        XCTAssertEqual(reloaded.map(\.id), history.map(\.id))
        XCTAssertEqual(reloaded.map(\.text), history.map(\.text))
    }

    func testReTranscriptionArchivesThePreviousRun() throws {
        try Data().write(to: noteFile)
        recordRunSuccess(file: noteFile, provider: "gemini", model: "flash-lite", audioDuration: 4,
                         startedAt: Date(), elapsedSeconds: 1, transcript: "first take",
                         speechStatus: .speech, rawResponse: nil)
        recordRunSuccess(file: noteFile, provider: "gemini", model: "3-flash", audioDuration: 4,
                         startedAt: Date(), elapsedSeconds: 1, transcript: "second take",
                         speechStatus: .speech, rawResponse: nil)
        // Same text again: nothing new to keep.
        recordRunSuccess(file: noteFile, provider: "gemini", model: "3-flash", audioDuration: 4,
                         startedAt: Date(), elapsedSeconds: 1, transcript: "second take",
                         speechStatus: .speech, rawResponse: nil)
        FileStore.upsertTranscriptionFields(for: noteFile, updates: ["localTranscript": "live take"])

        let variants = NoteTranscriptVariant.variants(forNoteFile: noteFile)
        XCTAssertEqual(variants.map(\.kind), [.realtime, .cloud, .previous])
        XCTAssertEqual(variants.map(\.text), ["live take", "second take", "first take"])
        XCTAssertEqual(variants.map(\.isCurrentRun), [false, true, false])
        XCTAssertEqual(variants.last?.model, "flash-lite")
    }

    func testPreviousRunsAreCapped() {
        var transcription: [String: Any] = [:]
        for i in 0..<(transcriptionPreviousRunsLimit + 3) {
            transcription["transcript"] = "take \(i)"
            archivePreviousRun(in: &transcription, replacingWith: "take \(i + 1)")
        }
        let runs = transcription[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
        XCTAssertEqual(runs.count, transcriptionPreviousRunsLimit)
        XCTAssertEqual(runs.last?["transcript"] as? String, "take \(transcriptionPreviousRunsLimit + 2)")
    }
}
