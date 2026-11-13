import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class SyncStateStoreTests: XCTestCase {
    private func temporaryState() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-ledger-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("state.json")
    }

    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)
    private enum Failure: Error { case offline }

    func testLegacySnapshotAndEveryStatusRecoverWithoutCheckpoint() async throws {
        let url = try temporaryState()
        let id = SyncRecordingID()
        let entry = RecordingSyncEntry(syncId: id, localRelativePath: "Recordings/old.m4a",
                                       status: .uploaded, updatedAt: stamp, retryCount: 2,
                                       cloudChangeTag: "old", localModifiedAt: stamp)
        let legacy = RecordingSyncState(entries: [id.rawValue: entry], lastSyncAt: stamp)
        try JSONEncoder.wimmSyncEncoder.encode(legacy).write(to: url)
        let store = SyncStateStore(stateURL: url)
        try await store.enqueueUpload(syncId: id, localURL: url, updatedAt: stamp)
        try await store.markFailed(id, error: Failure.offline, updatedAt: stamp)
        var recovered = await SyncStateStore(stateURL: url).entry(for: id)
        XCTAssertEqual(recovered?.status, .failed)
        XCTAssertEqual(recovered?.retryCount, 3)
        XCTAssertEqual(recovered?.localModifiedAt, stamp)
        XCTAssertEqual(recovered?.cloudChangeTag, "old")
        try await store.markUploaded(id, changeTag: "new", updatedAt: stamp, localModifiedAt: stamp.addingTimeInterval(10))
        recovered = await SyncStateStore(stateURL: url).entry(for: id)
        XCTAssertEqual(recovered?.status, .uploaded)
        XCTAssertEqual(recovered?.retryCount, 0)
        XCTAssertNil(recovered?.lastError)
        XCTAssertEqual(recovered?.cloudChangeTag, "new")
        XCTAssertEqual(recovered?.localModifiedAt, stamp.addingTimeInterval(10))
        try await store.markDownloaded(id, localURL: url, changeTag: "remote", updatedAt: stamp, localModifiedAt: stamp)
        try await store.updateLastSyncAt(stamp.addingTimeInterval(20))
        let snapshot = await SyncStateStore(stateURL: url).snapshot()
        XCTAssertEqual(snapshot.entries[id.rawValue]?.status, .downloaded)
        XCTAssertEqual(snapshot.lastSyncAt, stamp.addingTimeInterval(20))
        // No whole-ledger rewrite for these individual acknowledgements.
        XCTAssertEqual(try Data(contentsOf: url), try JSONEncoder.wimmSyncEncoder.encode(legacy))
    }

    func testInterruptedFinalAppendIsDiscardedBeforeNextWrite() async throws {
        let url = try temporaryState()
        let store = SyncStateStore(stateURL: url)
        let first = SyncRecordingID(), second = SyncRecordingID()
        try await store.enqueueUpload(syncId: first, localURL: url, updatedAt: stamp)
        let journal = SyncStateStore.journalURL(for: url)
        let handle = try FileHandle(forWritingTo: journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"sequence\":2,\"entries\":[".utf8))
        try handle.close()
        let recovered = SyncStateStore(stateURL: url)
        try await recovered.validatePersistence()
        try await recovered.enqueueUpload(syncId: second, localURL: url, updatedAt: stamp)
        let pending = await SyncStateStore(stateURL: url).entries(with: [.pendingUpload])
        XCTAssertEqual(Set(pending.map(\.syncId)), [first, second])
        XCTAssertEqual(try Data(contentsOf: journal).filter { $0 == 0x0A }.count, 2)
    }

    func testInterruptedCheckpointReplaysOldJournalIdempotently() async throws {
        let url = try temporaryState()
        let store = SyncStateStore(stateURL: url)
        let id = SyncRecordingID()
        try await store.enqueueUpload(syncId: id, localURL: url, updatedAt: stamp)
        try await store.markFailed(id, error: Failure.offline, updatedAt: stamp)
        let journal = SyncStateStore.journalURL(for: url)
        let beforeCheckpoint = try Data(contentsOf: journal)
        try await store.checkpoint()
        // Crash window: snapshot rename succeeded, journal truncation did not run.
        try beforeCheckpoint.write(to: journal)
        let recovered = SyncStateStore(stateURL: url)
        try await recovered.markUploaded(id, changeTag: "done", updatedAt: stamp)
        let final = await SyncStateStore(stateURL: url).entry(for: id)
        XCTAssertEqual(final?.status, .uploaded)
        XCTAssertEqual(final?.retryCount, 0)
        XCTAssertEqual(final?.cloudChangeTag, "done")
    }

    func testCorruptCompleteRecordAndSequenceGapFailClosed() async throws {
        for tail in ["not json\n", "{\"sequence\":3,\"entries\":[]}\n"] {
            let url = try temporaryState()
            let store = SyncStateStore(stateURL: url)
            try await store.enqueueUpload(syncId: SyncRecordingID(), localURL: url, updatedAt: stamp)
            let journal = SyncStateStore.journalURL(for: url)
            let handle = try FileHandle(forWritingTo: journal)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(tail.utf8))
            try handle.close()
            let original = try Data(contentsOf: journal)
            let damaged = SyncStateStore(stateURL: url)
            do {
                try await damaged.updateLastSyncAt(stamp)
                XCTFail("A damaged ledger must refuse writes")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: journal), original)
        }
    }

    func testFailedAppendDoesNotChangeMemoryOrPretendToAcknowledge() async throws {
        let url = try temporaryState()
        let store = SyncStateStore(stateURL: url)
        let journal = SyncStateStore.journalURL(for: url)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let id = SyncRecordingID()
        do {
            try await store.enqueueUpload(syncId: id, localURL: url)
            XCTFail("Writing to a directory should fail")
        } catch { }
        let entry = await store.entry(for: id)
        XCTAssertNil(entry)
        try FileManager.default.removeItem(at: journal)
        try await store.enqueueUpload(syncId: id, localURL: url)
        let recovered = await SyncStateStore(stateURL: url).entry(for: id)
        XCTAssertEqual(recovered?.status, .pendingUpload)
    }

    func testUnreadableSnapshotIsNotReplacedByEmptyLedger() async throws {
        let url = try temporaryState()
        let original = Data("broken snapshot".utf8)
        try original.write(to: url)
        let store = SyncStateStore(stateURL: url)
        do {
            try await store.enqueueUpload(syncId: SyncRecordingID(), localURL: url)
            XCTFail("A damaged snapshot must refuse writes")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SyncStateStore.journalURL(for: url).path))
    }

    func testCheckpointFailureRetainsAcknowledgedJournal() async throws {
        let url = try temporaryState()
        let store = SyncStateStore(stateURL: url)
        // Deny snapshot replacement after loading; the journal can still commit.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for _ in 0..<SyncStateStore.checkpointRecordLimit {
            try await store.enqueueUpload(syncId: SyncRecordingID(), localURL: url, updatedAt: stamp)
        }
        let journal = SyncStateStore.journalURL(for: url)
        let before = try Data(contentsOf: journal)
        do {
            try await store.updateLastSyncAt(stamp)
            XCTFail("Persistent checkpoint failure must bound further journal growth")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: journal), before)
        try FileManager.default.removeItem(at: url)
        let recovered = SyncStateStore(stateURL: url)
        try await recovered.validatePersistence()
        let pending = await recovered.entries(with: [.pendingUpload])
        XCTAssertEqual(pending.count, SyncStateStore.checkpointRecordLimit)
        try await recovered.markUploaded(pending[0].syncId, updatedAt: stamp)
        let stats = await recovered.persistenceStatistics()
        XCTAssertEqual(stats.snapshotWrites, 1)
        let final = await SyncStateStore(stateURL: url).entries(with: [.uploaded])
        XCTAssertEqual(final.count, 1)
    }

    func testBatchAndBoundedCheckpointPreserveVersionsAndQueue() async throws {
        let url = try temporaryState()
        let store = SyncStateStore(stateURL: url)
        let uploads = (0..<200).map { _ in (syncId: SyncRecordingID(), localURL: url, updatedAt: stamp) }
        try await store.enqueueUploads(uploads)
        try await store.setLocalModifiedAt([uploads[0].syncId: stamp])
        for upload in uploads { try await store.markUploaded(upload.syncId, updatedAt: stamp) }
        var stats = await store.persistenceStatistics()
        XCTAssertEqual(stats.journalWrites, 202)
        XCTAssertEqual(stats.snapshotWrites, 0)
        for _ in 202..<SyncStateStore.checkpointRecordLimit { try await store.updateLastSyncAt(stamp) }
        stats = await store.persistenceStatistics()
        XCTAssertEqual(stats.snapshotWrites, 1)
        XCTAssertEqual(try Data(contentsOf: SyncStateStore.journalURL(for: url)).count, 0)
        let recovered = await SyncStateStore(stateURL: url).snapshot()
        XCTAssertEqual(recovered.entries.count, 200)
        XCTAssertTrue(recovered.entries.values.allSatisfy { $0.status == .uploaded })
        XCTAssertEqual(recovered.entries[uploads[0].syncId.rawValue]?.localModifiedAt, stamp)
        XCTAssertEqual(recovered.lastSyncAt, stamp)
    }

    func testByteLimitAlsoTriggersCheckpoint() async throws {
        let url = try temporaryState()
        let store = SyncStateStore(stateURL: url)
        struct LargeFailure: Error, CustomStringConvertible {
            var description: String { String(repeating: "x", count: SyncStateStore.checkpointByteLimit) }
        }
        let id = SyncRecordingID()
        try await store.markFailed(id, error: LargeFailure(), updatedAt: stamp)
        let stats = await store.persistenceStatistics()
        XCTAssertEqual(stats.snapshotWrites, 1)
        let recovered = await SyncStateStore(stateURL: url).entry(for: id)
        XCTAssertEqual(recovered?.retryCount, 1)
    }

    private struct NoCloudTransport: CloudRecordingSyncTransport {
        func upload(bundle: LocalRecordingBundle) async throws -> String? { throw Failure.offline }
        func fetchChangeSummaries(since: Date?) async throws -> [RemoteRecordingSummary] { throw Failure.offline }
        func fetchBundle(syncId: SyncRecordingID, skipping: @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool) async throws -> RemoteRecordingBundle {
            throw Failure.offline
        }
        func markDeleted(syncId: SyncRecordingID, updatedAt: Date) async throws { throw Failure.offline }
    }

    func testLocalChangeScanCommitsTwoHundredUploadsAndLegacyBaselineOnce() async throws {
        let url = try temporaryState()
        var seed = RecordingSyncState()
        let baselineID = SyncRecordingID()
        for index in 0...200 {
            let file = url.deletingLastPathComponent().appendingPathComponent("note-\(index).txt")
            try Data("text".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: file.path)
            let id = index == 0 ? baselineID : SyncRecordingID()
            seed.entries[id.rawValue] = RecordingSyncEntry(
                syncId: id, localRelativePath: file.path, status: index == 0 ? .downloaded : .uploaded,
                updatedAt: stamp.addingTimeInterval(Double(index)), localModifiedAt: index == 0 ? nil : stamp
            )
        }
        try JSONEncoder.wimmSyncEncoder.encode(seed).write(to: url)
        let store = SyncStateStore(stateURL: url)
        let service = CloudRecordingSyncService(stateStore: store, transport: NoCloudTransport())
        let count = await service.enqueueLocalChanges()
        XCTAssertEqual(count, 200)
        let stats = await store.persistenceStatistics()
        XCTAssertEqual(stats.journalWrites, 1)
        let recovered = await SyncStateStore(stateURL: url).snapshot()
        XCTAssertEqual(recovered.entries.values.filter { $0.status == .pendingUpload }.count, 200)
        XCTAssertEqual(recovered.entries[baselineID.rawValue]?.localModifiedAt, stamp.addingTimeInterval(10))
        let again = await service.enqueueLocalChanges()
        XCTAssertEqual(again, 0)
        let noOpStats = await store.persistenceStatistics()
        XCTAssertEqual(noOpStats.journalWrites, 1)
    }

    func testSyncStopsBeforeCloudWhenLocalQueueCannotBeCommitted() async throws {
        let url = try temporaryState()
        let file = url.deletingLastPathComponent().appendingPathComponent("edited.txt")
        try Data("local edit".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: file.path)
        let id = SyncRecordingID()
        let seed = RecordingSyncState(entries: [id.rawValue: RecordingSyncEntry(
            syncId: id, localRelativePath: file.path, status: .uploaded,
            updatedAt: stamp, localModifiedAt: stamp
        )])
        try JSONEncoder.wimmSyncEncoder.encode(seed).write(to: url)
        let store = SyncStateStore(stateURL: url)
        try FileManager.default.createDirectory(at: SyncStateStore.journalURL(for: url), withIntermediateDirectories: true)
        let service = CloudRecordingSyncService(stateStore: store, transport: NoCloudTransport())
        do {
            try await service.syncNow()
            XCTFail("Cannot sync over an uncommitted local queue")
        } catch {
            XCTAssertFalse(error is Failure, "Cloud transport must not be called after the queue write fails")
        }
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.entries, seed.entries)
        XCTAssertNil(snapshot.lastSyncAt)
    }

    /// Opt-in reproducible comparison; no production library or network access.
    func testLedgerWriteBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["WIMM_SYNC_BENCHMARK"] == "1" else {
            throw XCTSkip("Set WIMM_SYNC_BENCHMARK=1 for the 6,598-entry disk benchmark")
        }
        let legacyURL = try temporaryState(), modernURL = try temporaryState()
        var seed = RecordingSyncState()
        var ids: [SyncRecordingID] = []
        for index in 0..<6_598 {
            let id = SyncRecordingID()
            ids.append(id)
            seed.entries[id.rawValue] = RecordingSyncEntry(
                syncId: id, localRelativePath: "Recordings/Wimm_2026-10-25_10-00-00_\(index).m4a",
                status: .uploaded, updatedAt: stamp, cloudChangeTag: "tag-\(index)", localModifiedAt: stamp
            )
        }
        let encoder = JSONEncoder.wimmSyncEncoder
        let initial = try encoder.encode(seed)
        try initial.write(to: legacyURL)
        try initial.write(to: modernURL)
        let requests = ids.prefix(200).map {
            (syncId: $0, localURL: modernURL.deletingLastPathComponent().appendingPathComponent("\($0).m4a"), updatedAt: stamp)
        }
        var legacy = seed
        var legacyBytes = 0
        let legacyStart = Date()
        for request in requests {
            var entry = legacy.entries[request.syncId.rawValue]!
            entry.localRelativePath = FileStore.relativePath(for: request.localURL)
            entry.status = .pendingUpload
            entry.updatedAt = stamp
            entry.lastError = nil
            legacy.entries[request.syncId.rawValue] = entry
            let data = try encoder.encode(legacy)
            legacyBytes += data.count
            try data.write(to: legacyURL, options: .atomic)
        }
        for request in requests {
            var entry = legacy.entries[request.syncId.rawValue]!
            entry.status = .uploaded
            entry.updatedAt = stamp
            entry.lastError = nil
            entry.retryCount = 0
            entry.cloudChangeTag = "new"
            entry.localModifiedAt = stamp
            legacy.entries[request.syncId.rawValue] = entry
            let data = try encoder.encode(legacy)
            legacyBytes += data.count
            try data.write(to: legacyURL, options: .atomic)
        }
        let legacySeconds = Date().timeIntervalSince(legacyStart)
        let store = SyncStateStore(stateURL: modernURL)
        let modernStart = Date()
        try await store.enqueueUploads(requests)
        for request in requests {
            try await store.markUploaded(request.syncId, changeTag: "new", updatedAt: stamp, localModifiedAt: stamp)
        }
        // Charge the new path a full checkpoint even though its 256-record
        // bound has not been reached yet (conservative steady-state comparison).
        try await store.checkpoint()
        let modernSeconds = Date().timeIntervalSince(modernStart)
        let stats = await store.persistenceStatistics()
        let recovered = await SyncStateStore(stateURL: modernURL).snapshot()
        XCTAssertEqual(recovered.entries, legacy.entries)
        print("LEDGER_BENCHMARK entries=6598 snapshot_bytes=\(initial.count) legacy_writes=400 legacy_bytes=\(legacyBytes) legacy_seconds=\(legacySeconds) journal_writes=\(stats.journalWrites) checkpoint_writes=\(stats.snapshotWrites) journal_bytes=\(stats.journalBytes) checkpoint_bytes=\(stats.snapshotBytes) modern_seconds=\(modernSeconds)")
    }
}
