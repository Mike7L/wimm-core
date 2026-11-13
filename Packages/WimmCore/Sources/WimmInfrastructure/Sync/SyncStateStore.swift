import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// The local ledger of what has been uploaded, downloaded or failed.

public enum RecordingSyncStatus: String, Codable, Sendable {
    case pendingUpload
    case uploaded
    case downloaded
    case failed
    /// Deleted on this device; the cloud tombstone has not landed yet. Kept
    /// until it does, so a delete made offline still reaches other devices.
    /// An older build that meets this value refuses the ledger (sync stops)
    /// rather than reading it as something else.
    case pendingDelete
}

public struct RecordingSyncEntry: Codable, Hashable, Sendable {
    public let syncId: SyncRecordingID
    public var localRelativePath: String
    public var status: RecordingSyncStatus
    public var updatedAt: Date
    public var lastError: String?
    public var retryCount: Int
    public var cloudChangeTag: String?
    /// The note's local version (newest of primary file and sidecar) when it
    /// last matched the cloud — after an upload or a download. A later local
    /// edit (transcript, card, OCR) pushes the version past this and the note
    /// is uploaded again. Nil for entries written before this existed.
    public var localModifiedAt: Date?

    public init(
        syncId: SyncRecordingID,
        localRelativePath: String,
        status: RecordingSyncStatus,
        updatedAt: Date = Date(),
        lastError: String? = nil,
        retryCount: Int = 0,
        cloudChangeTag: String? = nil,
        localModifiedAt: Date? = nil
    ) {
        self.syncId = syncId
        self.localRelativePath = localRelativePath
        self.status = status
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.retryCount = retryCount
        self.cloudChangeTag = cloudChangeTag
        self.localModifiedAt = localModifiedAt
    }
}

public struct RecordingSyncState: Codable, Hashable, Sendable {
    public var entries: [String: RecordingSyncEntry]
    public var lastSyncAt: Date?
    // Optional so the original state.json remains readable. Older readers also
    // ignore this key. Do not discard the journal when copying a live ledger.
    var journalSequence: UInt64?

    public init(entries: [String: RecordingSyncEntry] = [:], lastSyncAt: Date? = nil) {
        self.entries = entries
        self.lastSyncAt = lastSyncAt
    }
}

public actor SyncStateStore {
    private let stateURL: URL
    private let journalURL: URL
    private var state: RecordingSyncState
    private var journalBytes = 0
    private var journalRecords = 0
    private var persistenceError: Error?
    private var statistics = PersistenceStatistics()

    static let checkpointRecordLimit = 256
    static let checkpointByteLimit = 1_048_576

    struct PersistenceStatistics: Sendable {
        var journalWrites = 0
        var journalBytes = 0
        var snapshotWrites = 0
        var snapshotBytes = 0
    }

    func persistenceStatistics() -> PersistenceStatistics { statistics }

    private struct Change: Codable {
        var sequence: UInt64
        var entries: [RecordingSyncEntry]
        var lastSyncAt: Date?
    }

    private enum LedgerError: Error {
        case invalidJournalSequence
        case cannotCreateJournal
    }

    public init(stateURL: URL = FileStore.baseDirectory().appendingPathComponent("sync/state.json")) {
        self.stateURL = stateURL
        self.journalURL = Self.journalURL(for: stateURL)
        self.state = RecordingSyncState()
        do {
            self.state = try Self.loadSnapshot(from: stateURL)
            let recovered = try Self.replay(journalURL, into: &state)
            self.journalBytes = recovered.bytes
            self.journalRecords = recovered.records
        } catch {
            // Never turn a damaged ledger into an empty, writable one.
            self.persistenceError = error
            log("[CloudSync] ledger recovery failed: \(error)")
        }
    }

    static func journalURL(for stateURL: URL) -> URL {
        stateURL.appendingPathExtension("journal.jsonl")
    }

    public func validatePersistence() throws {
        if let persistenceError { throw persistenceError }
    }

    public func snapshot() -> RecordingSyncState {
        state
    }

    public func entries(with statuses: Set<RecordingSyncStatus>) -> [RecordingSyncEntry] {
        state.entries.values
            .filter { statuses.contains($0.status) }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func entry(for syncId: SyncRecordingID) -> RecordingSyncEntry? {
        state.entries[syncId.rawValue]
    }

    public func enqueueUpload(syncId: SyncRecordingID, localURL: URL, updatedAt: Date = Date()) throws {
        try enqueueUploads([(syncId, localURL, updatedAt)])
    }

    /// A scan commits its queue and legacy version baselines in one durable record.
    public func enqueueUploads(
        _ uploads: [(syncId: SyncRecordingID, localURL: URL, updatedAt: Date)],
        localVersions: [SyncRecordingID: Date] = [:]
    ) throws {
        var changed: [String: RecordingSyncEntry] = [:]
        for (syncId, version) in localVersions {
            guard var entry = state.entries[syncId.rawValue] else { continue }
            entry.localModifiedAt = version
            changed[syncId.rawValue] = entry
        }
        for upload in uploads {
            var entry = changed[upload.syncId.rawValue] ?? state.entries[upload.syncId.rawValue] ?? RecordingSyncEntry(
                syncId: upload.syncId,
                localRelativePath: FileStore.relativePath(for: upload.localURL),
                status: .pendingUpload,
                updatedAt: upload.updatedAt
            )
            entry.localRelativePath = FileStore.relativePath(for: upload.localURL)
            entry.status = .pendingUpload
            entry.updatedAt = upload.updatedAt
            entry.lastError = nil
            changed[upload.syncId.rawValue] = entry
        }
        guard !changed.isEmpty else { try validatePersistence(); return }
        try commit(entries: Array(changed.values))
    }

    public func markUploaded(_ syncId: SyncRecordingID, changeTag: String? = nil, updatedAt: Date = Date(), localModifiedAt: Date? = nil) throws {
        var entry = state.entries[syncId.rawValue] ?? RecordingSyncEntry(
            syncId: syncId,
            localRelativePath: "",
            status: .uploaded
        )
        entry.status = .uploaded
        entry.updatedAt = updatedAt
        entry.lastError = nil
        entry.retryCount = 0
        entry.cloudChangeTag = changeTag
        if let localModifiedAt { entry.localModifiedAt = localModifiedAt }
        try commit(entries: [entry])
    }

    public func markDownloaded(_ syncId: SyncRecordingID, localURL: URL, changeTag: String? = nil, updatedAt: Date = Date(), localModifiedAt: Date? = nil) throws {
        let entry = RecordingSyncEntry(
            syncId: syncId,
            localRelativePath: FileStore.relativePath(for: localURL),
            status: .downloaded,
            updatedAt: updatedAt,
            lastError: nil,
            retryCount: 0,
            cloudChangeTag: changeTag,
            localModifiedAt: localModifiedAt
        )
        try commit(entries: [entry])
    }

    /// Records baseline local versions in one write.
    public func setLocalModifiedAt(_ versions: [SyncRecordingID: Date]) throws {
        try enqueueUploads([], localVersions: versions)
    }

    public func markFailed(_ syncId: SyncRecordingID, error: Error, updatedAt: Date = Date()) throws {
        var entry = state.entries[syncId.rawValue] ?? RecordingSyncEntry(
            syncId: syncId,
            localRelativePath: "",
            status: .failed
        )
        entry.status = .failed
        entry.updatedAt = updatedAt
        entry.lastError = String(describing: error)
        entry.retryCount += 1
        try commit(entries: [entry])
    }

    /// Queues tombstones in one write. `localURL` is where the note lived
    /// before it was deleted, never its copy in Trash: a ledger path that
    /// exists would be read as a local edit and uploaded again.
    public func enqueueDeletions(
        _ deletions: [(syncId: SyncRecordingID, localURL: URL)],
        updatedAt: Date = Date()
    ) throws {
        guard !deletions.isEmpty else { try validatePersistence(); return }
        var changed: [String: RecordingSyncEntry] = [:]
        for deletion in deletions {
            var entry = state.entries[deletion.syncId.rawValue] ?? RecordingSyncEntry(
                syncId: deletion.syncId,
                localRelativePath: FileStore.relativePath(for: deletion.localURL),
                status: .pendingDelete,
                updatedAt: updatedAt
            )
            entry.localRelativePath = FileStore.relativePath(for: deletion.localURL)
            entry.status = .pendingDelete
            entry.updatedAt = updatedAt
            entry.lastError = nil
            entry.retryCount = 0
            changed[deletion.syncId.rawValue] = entry
        }
        try commit(entries: Array(changed.values))
    }

    /// A tombstone that did not reach the cloud stays queued; only the error
    /// and the attempt count change.
    public func markDeleteFailed(_ syncId: SyncRecordingID, error: Error) throws {
        guard var entry = state.entries[syncId.rawValue], entry.status == .pendingDelete else { return }
        entry.lastError = String(describing: error)
        entry.retryCount += 1
        try commit(entries: [entry])
    }

    public func updateLastSyncAt(_ date: Date) throws {
        try commit(entries: [], lastSyncAt: date)
    }

    private func commit(entries: [RecordingSyncEntry], lastSyncAt: Date? = nil) throws {
        try validatePersistence()
        // A previous compaction failure must not allow an ever-growing log.
        // Its acknowledged records stay intact; retry before accepting more.
        if journalRecords >= Self.checkpointRecordLimit || journalBytes >= Self.checkpointByteLimit {
            try checkpoint()
        }
        let change = Change(sequence: (state.journalSequence ?? 0) + 1, entries: entries, lastSyncAt: lastSyncAt)
        var data = try JSONEncoder.wimmSyncJournalEncoder.encode(change)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: nil) else {
                throw LedgerError.cannotCreateJournal
            }
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        do {
            // Discard an interrupted final append before extending the valid prefix.
            try handle.truncate(atOffset: UInt64(journalBytes))
            try handle.seek(toOffset: UInt64(journalBytes))
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            // An I/O failure may have committed an unknown prefix. Reopen/replay
            // before another mutation; do not reuse its sequence in this process.
            persistenceError = error
            throw error
        }
        for entry in entries { state.entries[entry.syncId.rawValue] = entry }
        if let lastSyncAt { state.lastSyncAt = lastSyncAt }
        state.journalSequence = change.sequence
        journalBytes += data.count
        journalRecords += 1
        statistics.journalWrites += 1
        statistics.journalBytes += data.count
        if journalRecords >= Self.checkpointRecordLimit || journalBytes >= Self.checkpointByteLimit {
            do { try checkpoint() }
            catch {
                // The mutation is already durable in the journal. Keep it and
                // retry compaction before the next write instead of failing its ACK.
                log("[CloudSync] ledger checkpoint failed (journal retained): \(error)")
            }
        }
    }

    /// Safe at any interruption point: write the numbered snapshot first, then
    /// clear the journal. Replaying old records after a crash is idempotent.
    func checkpoint() throws {
        try validatePersistence()
        let data = try JSONEncoder.wimmSyncEncoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
        let snapshot = try FileHandle(forWritingTo: stateURL)
        defer { try? snapshot.close() }
        try snapshot.synchronize()
        statistics.snapshotWrites += 1
        statistics.snapshotBytes += data.count
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let journal = try FileHandle(forWritingTo: journalURL)
            defer { try? journal.close() }
            // After truncation the old offset must never be used again, even
            // if synchronizing the truncation fails.
            try journal.truncate(atOffset: 0)
            journalBytes = 0
            journalRecords = 0
            try journal.synchronize()
        }
    }

    private static func loadSnapshot(from url: URL) throws -> RecordingSyncState {
        guard FileManager.default.fileExists(atPath: url.path) else { return RecordingSyncState() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder.wimmSyncDecoder.decode(RecordingSyncState.self, from: data)
    }

    private static func replay(_ url: URL, into state: inout RecordingSyncState) throws -> (bytes: Int, records: Int) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (0, 0) }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder.wimmSyncDecoder
        var start = data.startIndex
        var records = 0
        let checkpointSequence = state.journalSequence ?? 0
        for end in data.indices where data[end] == 0x0A {
            let change = try decoder.decode(Change.self, from: data[start..<end])
            if change.sequence > checkpointSequence {
                guard change.sequence == (state.journalSequence ?? 0) + 1 else {
                    throw LedgerError.invalidJournalSequence
                }
                for entry in change.entries { state.entries[entry.syncId.rawValue] = entry }
                if let date = change.lastSyncAt { state.lastSyncAt = date }
                state.journalSequence = change.sequence
            }
            records += 1
            start = end + 1
        }
        // A non-newline-terminated tail was never acknowledged as a record.
        return (start, records)
    }
}
