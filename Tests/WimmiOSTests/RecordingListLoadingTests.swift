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
