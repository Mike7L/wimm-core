import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// `FileSystemAdapter.deleteNote` (HUD `d`, `wimm-cli tui delete`, `clean
/// --force`) is a user's delete: the files go to Trash, never `removeItem`,
/// and a synced note queues its iCloud tombstone.
final class FileSystemAdapterTrashTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-adapter-trash-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", base.path, 1)
        try FileStore.ensureDirectoryExists()
    }

    override func tearDownWithError() throws {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    private var stateURL: URL { base.appendingPathComponent("state.json") }

    private func sidecar(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testDeleteMovesMediaAndSidecarToTrashWithMarker() async throws {
        let adapter = FileSystemAdapter(rootDirectory: base)
        let note = try await adapter.saveRecording(
            data: Data("audio".utf8), fileName: "Wimm_2026-11-15_10-00-00.m4a", initialText: "invented text")
        let audio = FileStore.recordingsDirectory().appendingPathComponent("Wimm_2026-11-15_10-00-00.m4a")
        let meta = FileStore.recordingsDirectory().appendingPathComponent("Wimm_2026-11-15_10-00-00.meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: meta.path))

        try await adapter.deleteNote(id: note.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meta.path))
        let trashedAudio = FileStore.trashDirectory().appendingPathComponent(audio.lastPathComponent)
        let trashedMeta = FileStore.trashDirectory().appendingPathComponent(meta.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: trashedAudio), Data("audio".utf8), "the original survives in Trash")
        let marker = try sidecar(trashedMeta)
        XCTAssertEqual(marker["trashed"] as? Bool, true)
        XCTAssertEqual(marker["originalPath"] as? String, audio.path)
        XCTAssertEqual(marker["text"] as? String, "invented text")

        let remaining = try await adapter.loadAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeleteOfSyncedNoteQueuesTombstone() async throws {
        let transport = AdapterTrashFakeTransport()
        let service = CloudRecordingSyncService(stateStore: SyncStateStore(stateURL: stateURL), transport: transport)
        let adapter = FileSystemAdapter(rootDirectory: base, cloudSync: service)
        let note = try await adapter.saveRecording(
            data: Data("audio".utf8), fileName: "synced.m4a", initialText: "invented text")
        let audio = FileStore.recordingsDirectory().appendingPathComponent("synced.m4a")
        let syncId = try await service.enqueueNewRecording(audio)
        try await service.syncNow()
        XCTAssertEqual(transport.uploaded, [syncId])

        try await adapter.deleteNote(id: note.id)

        XCTAssertEqual(transport.deleted, [syncId], "the delete reached iCloud as a tombstone")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: FileStore.trashDirectory().appendingPathComponent("synced.m4a").path))
    }

    func testOfflineDeleteStillTrashesAndLeavesTombstoneQueued() async throws {
        let transport = AdapterTrashFakeTransport()
        let service = CloudRecordingSyncService(stateStore: SyncStateStore(stateURL: stateURL), transport: transport)
        let adapter = FileSystemAdapter(rootDirectory: base, cloudSync: service)
        let note = try await adapter.saveRecording(
            data: Data("audio".utf8), fileName: "offline.m4a", initialText: "invented text")
        let audio = FileStore.recordingsDirectory().appendingPathComponent("offline.m4a")
        let syncId = try await service.enqueueNewRecording(audio)
        try await service.syncNow()

        transport.offline = true
        try await adapter.deleteNote(id: note.id)

        XCTAssertTrue(transport.deleted.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        let entry = await SyncStateStore(stateURL: stateURL).entry(for: syncId)
        XCTAssertEqual(entry?.status, .pendingDelete)
    }

    func testDeleteOfSidecarOnlyNoteMovesSidecarToTrash() async throws {
        let id = UUID()
        let meta = FileStore.recordingsDirectory().appendingPathComponent("\(id.uuidString).meta.json")
        let payload: [String: Any] = ["id": id.uuidString, "createdAt": "2026-11-15T10:00:00Z", "text": "orphan"]
        try JSONSerialization.data(withJSONObject: payload).write(to: meta)
        // A trashed file of the same name must not be overwritten.
        try FileManager.default.createDirectory(at: FileStore.trashDirectory(), withIntermediateDirectories: true)
        let older = FileStore.trashDirectory().appendingPathComponent(meta.lastPathComponent)
        try Data("{\"text\":\"older\"}".utf8).write(to: older)

        let adapter = FileSystemAdapter(rootDirectory: base)
        _ = try await adapter.loadAll()
        try await adapter.deleteNote(id: id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: meta.path))
        XCTAssertEqual(try sidecar(older)["text"] as? String, "older")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: FileStore.trashDirectory().path)
            .filter { $0 != older.lastPathComponent && $0.hasSuffix(".meta.json") }
        XCTAssertEqual(trashed.count, 1)
        let marker = try sidecar(FileStore.trashDirectory().appendingPathComponent(trashed[0]))
        XCTAssertEqual(marker["trashed"] as? Bool, true)
        XCTAssertEqual(marker["text"] as? String, "orphan")
        let remaining = try await adapter.loadAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testDeleteOfUnknownNoteThrows() async throws {
        let adapter = FileSystemAdapter(rootDirectory: base)
        do {
            try await adapter.deleteNote(id: UUID())
            XCTFail("expected noteNotFound")
        } catch StorageError.noteNotFound {
        }
    }
}

private final class AdapterTrashFakeTransport: CloudRecordingSyncTransport, @unchecked Sendable {
    struct Offline: Error {}
    var offline = false
    private(set) var uploaded: [SyncRecordingID] = []
    private(set) var deleted: [SyncRecordingID] = []

    func upload(bundle: LocalRecordingBundle) async throws -> String? {
        if offline { throw Offline() }
        uploaded.append(bundle.manifest.syncId)
        return "tag"
    }

    func fetchChangeSummaries(since: Date?) async throws -> [RemoteRecordingSummary] {
        if offline { throw Offline() }
        return []
    }

    func fetchBundle(
        syncId: SyncRecordingID,
        skipping: @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool
    ) async throws -> RemoteRecordingBundle {
        throw RecordingSyncError.invalidCloudPayload("not in this fake")
    }

    func markDeleted(syncId: SyncRecordingID, updatedAt: Date) async throws {
        if offline { throw Offline() }
        deleted.append(syncId)
    }
}
