import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// A note deleted on the Mac must reach iCloud as a tombstone, also when the
/// Mac is offline, and a restore must bring it back on other devices.
final class CloudSyncTombstoneTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-tombstone-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", base.path, 1)
        try FileStore.ensureDirectoryExists()
        try FileManager.default.createDirectory(at: FileStore.trashDirectory(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    private var stateURL: URL { base.appendingPathComponent("state.json") }

    private func ledgerBytes() -> [Data?] {
        [stateURL, SyncStateStore.journalURL(for: stateURL)].map { try? Data(contentsOf: $0) }
    }

    private func makeService(_ transport: TombstoneFakeTransport) -> CloudRecordingSyncService {
        CloudRecordingSyncService(stateStore: SyncStateStore(stateURL: stateURL), transport: transport)
    }

    /// A note that went up once, as after a normal recording.
    private func makeSyncedNote(
        _ name: String,
        service: CloudRecordingSyncService
    ) async throws -> (URL, SyncRecordingID) {
        let url = FileStore.recordingsDirectory().appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        let syncId = try await service.enqueueNewRecording(url)
        try await service.syncNow()
        return (url, syncId)
    }

    func testMacTrashSendsTombstoneAndNeverReuploadsTrashedNote() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let (note, syncId) = try await makeSyncedNote("Wimm_2026-11-09_10-00-00_A.m4a", service: service)
        XCTAssertEqual(transport.uploaded, [syncId])

        let trashed = try await TrashRepository().moveToTrash(file: note).unwrapped()
        let sent = try await service.markTrashed(trashedURL: trashed, originalURL: note)

        XCTAssertTrue(sent)
        XCTAssertEqual(transport.deleted, [syncId])
        let entry = await SyncStateStore(stateURL: stateURL).entry(for: syncId)
        XCTAssertEqual(entry?.status, .uploaded)
        XCTAssertEqual(entry?.localRelativePath, FileStore.relativePath(for: note),
                       "the ledger keeps the old place, never the Trash copy")

        // The Trash move wrote a marker into the sidecar (a newer version):
        // it must not be read as a local edit and sent up as a live note.
        try await service.syncNow()
        XCTAssertEqual(transport.uploaded, [syncId])
    }

    func testOfflineDeleteStaysQueuedAcrossRestartAndIsSentLater() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let (note, syncId) = try await makeSyncedNote("offline.m4a", service: service)

        transport.offline = true
        let trashed = try await TrashRepository().moveToTrash(file: note).unwrapped()
        try await service.markTrashed(trashedURL: trashed, originalURL: note)

        XCTAssertTrue(transport.deleted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path), "the local delete never waits on iCloud")
        let queued = await SyncStateStore(stateURL: stateURL).entry(for: syncId)
        XCTAssertEqual(queued?.status, .pendingDelete)
        XCTAssertEqual(queued?.retryCount, 1)
        XCTAssertNotNil(queued?.lastError)

        // App restarts, comes back online.
        transport.offline = false
        let restarted = makeService(transport)
        try await restarted.syncNow()

        XCTAssertEqual(transport.deleted, [syncId])
        let done = await SyncStateStore(stateURL: stateURL).entry(for: syncId)
        XCTAssertEqual(done?.status, .uploaded)
        XCTAssertEqual(transport.uploaded, [syncId], "a pending delete is never uploaded as a note")
    }

    func testOlderRemoteVersionDoesNotReinstallANoteDeletedHere() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let (note, syncId) = try await makeSyncedNote("stale.m4a", service: service)
        transport.offline = true
        let trashed = try await TrashRepository().moveToTrash(file: note).unwrapped()
        try await service.markTrashed(trashedURL: trashed, originalURL: note)

        transport.offline = false
        transport.remote = [RemoteRecordingSummary(
            syncId: syncId, updatedAt: Date().addingTimeInterval(-60), isDeleted: false, filenamePrefix: "stale"
        )]
        _ = try await service.downloadRemoteChanges(fullScan: true)

        XCTAssertTrue(transport.fetched.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
    }

    func testRestoreFromTrashUploadsTheNoteAgain() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let (note, syncId) = try await makeSyncedNote("restore.m4a", service: service)
        let trash = TrashRepository()
        let trashed = try await trash.moveToTrash(file: note).unwrapped()
        try await service.markTrashed(trashedURL: trashed, originalURL: note)
        XCTAssertEqual(transport.deleted, [syncId])

        let restored = try await trash.restoreFromTrash(file: trashed).unwrapped()
        let queued = try await service.markRestored(recordingURL: restored)
        try await service.uploadPending()

        XCTAssertTrue(queued)
        XCTAssertEqual(transport.uploaded, [syncId, syncId])
        XCTAssertEqual(transport.lastUploadIsDeleted, false)
    }

    func testRestoreBeforeTheTombstoneLeftCancelsIt() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let (note, syncId) = try await makeSyncedNote("undo.m4a", service: service)
        transport.offline = true
        let trash = TrashRepository()
        let trashed = try await trash.moveToTrash(file: note).unwrapped()
        try await service.markTrashed(trashedURL: trashed, originalURL: note)
        let restored = try await trash.restoreFromTrash(file: trashed).unwrapped()
        try await service.markRestored(recordingURL: restored)

        transport.offline = false
        try await service.syncNow()

        XCTAssertTrue(transport.deleted.isEmpty)
        XCTAssertEqual(transport.uploaded, [syncId, syncId])
    }

    func testNeverSyncedNoteSendsNoTombstone() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let note = FileStore.recordingsDirectory().appendingPathComponent("local-only.m4a")
        try Data("audio".utf8).write(to: note)
        // A note id alone (every note has one) does not mean a cloud record exists.
        FileStore.upsertMetadata(for: note, updates: [RecordingIdentity.metadataKey: UUID().uuidString])

        let trashed = try await TrashRepository().moveToTrash(file: note).unwrapped()
        let sent = try await service.markTrashed(trashedURL: trashed, originalURL: note)

        XCTAssertFalse(sent)
        XCTAssertTrue(transport.deleted.isEmpty)
    }

    func testTrashBackfillPlanSkipsUnsyncedAndLiveNotesAndWritesNothing() async throws {
        let transport = TombstoneFakeTransport()
        let service = makeService(transport)
        let trashDir = FileStore.trashDirectory()
        let recordings = FileStore.recordingsDirectory()

        // Moved by hand: in Trash, sidecar with a syncId, no `trashed` marker.
        let (gone, goneId) = try await makeSyncedNote("gone.m4a", service: service)
        for url in [gone, FileStore.metadataURL(forRecordingURL: gone)] {
            try FileManager.default.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
        }
        // Never synced.
        let unsynced = trashDir.appendingPathComponent("unsynced.m4a")
        try Data("audio".utf8).write(to: unsynced)
        // A copy whose twin with the same syncId is still alive.
        let (_, liveId) = try await makeSyncedNote("alive.m4a", service: service)
        let twin = trashDir.appendingPathComponent("alive-copy.m4a")
        try Data("audio".utf8).write(to: twin)
        FileStore.upsertMetadata(for: twin, updates: [RecordingSyncMetadata.syncIdKey: liveId.rawValue])
        // Derived audio and a PDF's first-page render are not notes.
        try Data("micro".utf8).write(to: trashDir.appendingPathComponent("gone_micro.m4a"))
        let pdf = trashDir.appendingPathComponent("scan.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        try Data("img".utf8).write(to: trashDir.appendingPathComponent("scan.heic"))
        let pdfId = SyncRecordingID()
        FileStore.upsertMetadata(for: pdf, updates: [RecordingSyncMetadata.syncIdKey: pdfId.rawValue])

        let ledgerBefore = ledgerBytes()
        let ledger = await SyncStateStore(stateURL: stateURL).snapshot()
        let plan = TrashTombstoneBackfill.plan(ledger: ledger)

        XCTAssertEqual(plan.scanned, 4)
        XCTAssertEqual(plan.items.map(\.syncId), [goneId, pdfId])
        XCTAssertEqual(plan.items.first?.originalURL.lastPathComponent, "gone.m4a")
        XCTAssertEqual(plan.items.first?.originalURL.deletingLastPathComponent().standardizedFileURL,
                       recordings.standardizedFileURL)
        XCTAssertEqual(plan.byLedgerStatus, ["uploaded": 1, "none": 1])
        XCTAssertEqual(plan.skipped[.noSyncId]?.map(\.lastPathComponent), ["unsynced.m4a"])
        XCTAssertEqual(plan.skipped[.aliveInRecordings]?.map(\.lastPathComponent), ["alive-copy.m4a"])
        XCTAssertEqual(ledgerBytes(), ledgerBefore, "planning never writes")
        XCTAssertTrue(transport.deleted.isEmpty)

        // --from-log narrows the scan to the logged files.
        let log = base.appendingPathComponent("trash_log.json")
        let pairs = [[recordings.appendingPathComponent("unsynced.m4a").path, unsynced.path]]
        try JSONSerialization.data(withJSONObject: pairs).write(to: log)
        let narrowed = TrashTombstoneBackfill.plan(
            ledger: ledger,
            onlyNames: try TrashTombstoneBackfill.trashedNames(fromLog: log)
        )
        XCTAssertTrue(narrowed.items.isEmpty)
        XCTAssertEqual(narrowed.skipped[.notInLog]?.count, 3)

        // Apply = queue + send; a second plan then finds nothing left.
        let result = try await service.markDeleted(plan.items.map { ($0.syncId, $0.originalURL) })
        XCTAssertEqual(result.sent, 2)
        XCTAssertEqual(Set(transport.deleted), [goneId, pdfId])
        let after = TrashTombstoneBackfill.plan(ledger: await SyncStateStore(stateURL: stateURL).snapshot())
        XCTAssertEqual(after.items.map(\.syncId), [goneId, pdfId], "sent tombstones are not pending; re-running only re-sends")
    }
}

private struct MissingValue: Error {}

private extension Optional {
    func unwrapped() throws -> Wrapped {
        guard let self else { throw MissingValue() }
        return self
    }
}

private final class TombstoneFakeTransport: CloudRecordingSyncTransport, @unchecked Sendable {
    struct Offline: Error {}
    var offline = false
    var remote: [RemoteRecordingSummary] = []
    private(set) var uploaded: [SyncRecordingID] = []
    private(set) var lastUploadIsDeleted: Bool?
    private(set) var deleted: [SyncRecordingID] = []
    private(set) var fetched: [SyncRecordingID] = []

    func upload(bundle: LocalRecordingBundle) async throws -> String? {
        if offline { throw Offline() }
        uploaded.append(bundle.manifest.syncId)
        lastUploadIsDeleted = bundle.manifest.isDeleted
        return "tag"
    }

    func fetchChangeSummaries(since: Date?) async throws -> [RemoteRecordingSummary] {
        if offline { throw Offline() }
        return remote
    }

    func fetchBundle(
        syncId: SyncRecordingID,
        skipping: @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool
    ) async throws -> RemoteRecordingBundle {
        fetched.append(syncId)
        throw RecordingSyncError.invalidCloudPayload("not in this fake")
    }

    func markDeleted(syncId: SyncRecordingID, updatedAt: Date) async throws {
        if offline { throw Offline() }
        deleted.append(syncId)
    }
}
