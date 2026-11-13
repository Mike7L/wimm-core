import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

private actor FakeSyncService: StudioSyncService {
    func subscribeToChanges() async {}
    var syncs: [Bool] = []
    var enqueued: [URL] = []
    var uploads = 0
    var applyRemoteChanges = false
    var failure: Error?
    var holdSync = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func configure(applyRemoteChanges: Bool = false, failure: Error? = nil, holdSync: Bool = false) {
        self.applyRemoteChanges = applyRemoteChanges; self.failure = failure; self.holdSync = holdSync
    }
    func release() { held.forEach { $0.resume() }; held.removeAll(); holdSync = false }

    func syncNow(fullScan: Bool, recentOnly: Bool) async throws -> Bool {
        syncs.append(fullScan)
        if holdSync { await withCheckedContinuation { held.append($0) } }
        if let failure { throw failure }
        return applyRemoteChanges
    }
    func enqueueNewRecording(_ recordingURL: URL) async throws -> SyncRecordingID {
        enqueued.append(recordingURL)
        return SyncRecordingID()
    }
    func uploadPending() async throws { uploads += 1 }
    func drainFreshlyDownloaded() async -> [URL] { [] }
}

private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

final class StudioCloudSyncTests: XCTestCase {
    @MainActor func testWithoutServiceEverythingIsANoOp() async {
        let sync = StudioCloudSync(service: nil, onRemoteChanges: { XCTFail("no service, no reload") })
        XCTAssertFalse(sync.isAvailable)
        let applied = await sync.sync(fullScan: true)
        XCTAssertFalse(applied)
        sync.noteChanged(URL(fileURLWithPath: "/tmp/x.txt"))
        sync.start()
        await sync.activate()
        XCTAssertNil(sync.lastSyncAt)
    }

    @MainActor func testReloadsLibraryOnlyWhenRemoteChangesWereApplied() async {
        let service = FakeSyncService()
        var reloads = 0
        let sync = StudioCloudSync(service: service, onRemoteChanges: { reloads += 1 })
        await service.configure(applyRemoteChanges: false)
        let first = await sync.sync(fullScan: false)
        XCTAssertFalse(first)
        XCTAssertEqual(reloads, 0)
        await service.configure(applyRemoteChanges: true)
        let second = await sync.sync(fullScan: true)
        XCTAssertTrue(second)
        XCTAssertEqual(reloads, 1)
        let syncs = await service.syncs
        XCTAssertEqual(syncs, [false, true])
        XCTAssertNotNil(sync.lastSyncAt)
        XCTAssertNil(sync.lastError)
    }

    @MainActor func testFailureIsReportedAndDoesNotReload() async {
        let service = FakeSyncService()
        await service.configure(applyRemoteChanges: true, failure: Boom())
        let sync = StudioCloudSync(service: service, onRemoteChanges: { XCTFail("failed pass must not reload") })
        let applied = await sync.sync(fullScan: true)
        XCTAssertFalse(applied)
        XCTAssertEqual(sync.lastError, "boom")
        XCTAssertNil(sync.lastSyncAt)
        // A later good pass clears the error.
        await service.configure(applyRemoteChanges: false)
        await sync.sync(fullScan: true)
        XCTAssertNil(sync.lastError)
        XCTAssertNotNil(sync.lastSyncAt)
    }

    @MainActor func testPassesNeverOverlap() async {
        let service = FakeSyncService()
        await service.configure(holdSync: true)
        let sync = StudioCloudSync(service: service, onRemoteChanges: {})
        let running = Task { await sync.sync(fullScan: true) }
        while !sync.isSyncing { await Task.yield() }
        let overlapping = await sync.sync(fullScan: true)
        XCTAssertFalse(overlapping)
        await service.release()
        _ = await running.value
        let syncs = await service.syncs
        XCTAssertEqual(syncs.count, 1)
        XCTAssertFalse(sync.isSyncing)
    }

    @MainActor func testActivationRespectsMinimumGap() async {
        let service = FakeSyncService()
        let sync = StudioCloudSync(service: service, onRemoteChanges: {})
        await sync.activate()
        await sync.activate()
        let syncs = await service.syncs
        XCTAssertEqual(syncs, [false], "second activation inside the gap must not sync")
    }

    @MainActor func testSavedNotesAreBatchedIntoOneUpload() async {
        let service = FakeSyncService()
        let sync = StudioCloudSync(service: service, uploadDelay: .milliseconds(30), onRemoteChanges: {})
        let a = URL(fileURLWithPath: "/tmp/a.m4a"), b = URL(fileURLWithPath: "/tmp/b.txt")
        // A recording reports twice (audio durable, then final text).
        sync.noteChanged(a); sync.noteChanged(a); sync.noteChanged(b)
        try? await Task.sleep(for: .milliseconds(300))
        let enqueued = await service.enqueued
        let uploads = await service.uploads
        XCTAssertEqual(Set(enqueued), [a, b])
        XCTAssertEqual(enqueued.count, 2)
        XCTAssertEqual(uploads, 1)
    }

    @MainActor func testFlushWithNothingPendingStillUploadsQueue() async {
        let service = FakeSyncService()
        let sync = StudioCloudSync(service: service, onRemoteChanges: {})
        await sync.flushUploads()
        let enqueued = await service.enqueued
        let uploads = await service.uploads
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertEqual(uploads, 1)
    }
}
