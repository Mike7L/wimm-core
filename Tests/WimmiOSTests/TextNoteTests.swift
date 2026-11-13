import XCTest
import WimmDomain
@testable import WimmiOSApp

@MainActor
final class TextNoteTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", base.path, 1)
    }

    override func tearDown() async throws {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    func testWrittenEntryBecomesAPublishedTextNoteAndSyncs() async throws {
        let state = SyncRecordingAppState(audioRecorder: ReliableRecorder(), startServices: false)

        try await state.createTextNote("  Купить хлеб. И молоко.\n")
        await state.waitForSync()

        let note = try XCTUnwrap(state.recordings.first)
        XCTAssertEqual(note.fileURL.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: note.fileURL, encoding: .utf8), "Купить хлеб. И молоко.")
        XCTAssertEqual(note.note?.refined_text, "Купить хлеб. И молоко.")
        XCTAssertFalse(note.note?.title.isEmpty ?? true)
        XCTAssertEqual(state.syncedURLs.map(\.lastPathComponent), [note.fileURL.lastPathComponent])
    }

    func testBlankEntryCreatesNothing() async throws {
        let state = SyncRecordingAppState(audioRecorder: ReliableRecorder(), startServices: false)

        try await state.createTextNote(" \n\t ")

        XCTAssertTrue(state.recordings.isEmpty)
        XCTAssertEqual(state.syncedURLs, [])
    }
}

@MainActor
private final class SyncRecordingAppState: AppState {
    private(set) var syncedURLs: [URL] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override func enqueueSync(for url: URL) async {
        syncedURLs.append(url)
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitForSync() async {
        guard syncedURLs.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
