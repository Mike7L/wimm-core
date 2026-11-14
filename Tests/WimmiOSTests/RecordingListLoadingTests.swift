import XCTest
import WimmDomain
@testable import WimmiOSApp

@MainActor
final class RecordingListLoadingTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("WIMM_BASE_DIR", base.path, 1)
        try FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    private func writeNote(_ name: String) throws -> URL {
        let url = FileStore.recordingsDirectory().appendingPathComponent(name + ".txt")
        try name.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCaptureDuringLoadKeepsBothExistingLibraryAndNewNote() async throws {
        let old = try writeNote("old")
        let other = try writeNote("other")
        let state = PausedListAppState(startServices: false)
        let load = Task { await state.loadRecordings() }
        await fulfillment(of: [state.paused], timeout: 2)

        let new = try writeNote("new")
        await state.publishRecording(at: new)
        XCTAssertEqual(state.recordings.map(\.fileURL), [new])
        state.resume()
        await load.value

        XCTAssertEqual(Set(state.recordings.map(\.fileURL)), Set([old, other, new]))
        XCTAssertFalse(state.isLoading)
    }

    func testFirstBatchIsVisibleBeforeWholeLibraryFinishes() async throws {
        for index in 0..<51 { _ = try writeNote("note-\(index)") }
        let state = PausedListAppState(startServices: false)
        state.pauseAt = 51
        let load = Task { await state.loadRecordings() }
        await fulfillment(of: [state.paused], timeout: 5)
        XCTAssertEqual(state.recordings.count, 50)
        XCTAssertTrue(state.isLoading)
        state.resume()
        await load.value
        XCTAssertEqual(state.recordings.count, 51)
        XCTAssertFalse(state.isLoading)
    }

    func testNewerReloadWinsOverSuspendedOldSnapshot() async throws {
        let old = try writeNote("old")
        let state = PausedListAppState(startServices: false)
        let load = Task { await state.loadRecordings() }
        await fulfillment(of: [state.paused], timeout: 2)
        try FileManager.default.removeItem(at: old)
        let replacement = try writeNote("replacement")
        await state.repository.invalidateCache()
        await state.loadRecordings()
        state.resume()
        await load.value
        XCTAssertEqual(state.recordings.map(\.fileURL), [replacement])
        XCTAssertFalse(state.isLoading)
    }

    /// Battery drain 2026-11-12: every note listed the whole folder again, O(N²)
    /// over the library on each launch and return to the foreground.
    func testListLoadListsTheFolderOncePerLoadNotPerNote() async throws {
        for index in 0..<120 { _ = try writeNote("note-\(index)") }
        let state = AppState(startServices: false)
        await state.loadRecordings()
        XCTAssertEqual(state.recordings.count, 120)
        XCTAssertEqual(state.listDirectoryIndexBuilds, 1)
        await state.loadRecordings()
        XCTAssertEqual(state.listDirectoryIndexBuilds, 2)
    }

    /// A repeat load reuses rows whose file and sidecar are unchanged and
    /// rebuilds only the changed ones.
    func testRepeatLoadReusesUnchangedRowsAndRebuildsChangedOnes() async throws {
        for index in 0..<30 { _ = try writeNote("note-\(index)") }
        let state = AppState(startServices: false)
        await state.loadRecordings()
        XCTAssertEqual(state.listItemBuilds, 30)

        await state.repository.invalidateCache()
        await state.loadRecordings()
        XCTAssertEqual(state.listItemBuilds, 30, "nothing changed, nothing rebuilt")

        let edited = FileStore.recordingsDirectory().appendingPathComponent("note-7.txt")
        try "edited body text".write(to: edited, atomically: true, encoding: .utf8)
        let added = try writeNote("added")
        try FileManager.default.removeItem(at: FileStore.recordingsDirectory().appendingPathComponent("note-3.txt"))
        await state.repository.invalidateCache()
        await state.loadRecordings()
        XCTAssertEqual(state.listItemBuilds, 32, "only the edited and the added note")
        XCTAssertEqual(state.recordings.count, 30)
        XCTAssertEqual(state.recordings.first { $0.fileURL == edited }?.titlePreview, "edited body text")
        XCTAssertTrue(state.recordings.contains { $0.fileURL == added })

        let sidecar = FileStore.metadataURL(forRecordingURL: added)
        try #"{"duration": 12.5}"#.write(to: sidecar, atomically: true, encoding: .utf8)
        await state.repository.invalidateCache()
        await state.loadRecordings()
        XCTAssertEqual(state.listItemBuilds, 33, "a sidecar change rebuilds its row")
        XCTAssertEqual(state.recordings.first { $0.fileURL == added }?.durationSeconds, 12.5)
    }

    func testAudioListUsesStoredDurationEvenWhenAudioCannotBeOpened() async throws {
        let url = FileStore.recordingsDirectory().appendingPathComponent("unfinished.m4a")
        try Data().write(to: url)
        try RecordingMetadata(recordingURL: url, duration: 42, isComplete: true).save()
        let state = AppState(startServices: false)
        await state.loadRecordings()
        XCTAssertEqual(state.recordings.map(\.fileURL), [url])
        XCTAssertEqual(state.recordings.first?.durationSeconds, 42)
    }
}

@MainActor
private final class PausedListAppState: AppState {
    let paused = XCTestExpectation(description: "List scan paused")
    var pauseAt = 1
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    override func recordingListItem(for url: URL) async -> Recording {
        count += 1
        if count == pauseAt {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                paused.fulfill()
            }
        }
        return await super.recordingListItem(for: url)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
