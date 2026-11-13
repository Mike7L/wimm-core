import Foundation
import WimmDomain

/// One-off catch-up for notes deleted on the Mac before Mac deletes sent a
/// cloud tombstone (fixed 2026-11-09): they sit in Trash here but are still
/// alive in iCloud and on the iPhone. Planning is read-only; `apply` queues
/// the tombstones in the sync ledger and sends them.
public enum TrashTombstoneBackfill {
    public enum SkipReason: String, Sendable, CaseIterable {
        /// Never synced: the cloud has nothing to delete.
        case noSyncId = "no_sync_id"
        /// A note with the same sync id is alive in Recordings (restored,
        /// or a duplicate): deleting the record would remove a live note.
        case aliveInRecordings = "alive_in_recordings"
        /// Already queued as a tombstone.
        case alreadyPending = "already_pending"
        /// Not among the files the `--from-log` list names.
        case notInLog = "not_in_log"
    }

    public struct Item: Sendable, Hashable {
        public let trashedURL: URL
        public let syncId: SyncRecordingID
        /// Where the note lived; becomes the ledger's path.
        public let originalURL: URL
        /// Ledger status before the backfill, nil when this Mac has no entry.
        public let ledgerStatus: RecordingSyncStatus?
    }

    public struct Plan: Sendable {
        public var scanned = 0
        public var items: [Item] = []
        public var skipped: [SkipReason: [URL]] = [:]

        public var byLedgerStatus: [String: Int] {
            Dictionary(grouping: items, by: { $0.ledgerStatus?.rawValue ?? "none" }).mapValues(\.count)
        }
    }

    /// Primary note files in `trashDirectory` (no sidecars, no derived audio).
    public static func trashedNotes(in trashDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        let items = (try? fileManager.contentsOfDirectory(
            at: trashDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let notes = items.filter { url in
            let ext = url.pathExtension.lowercased()
            if FileStore.supportedAudioExtensions.contains(ext) { return !FileStore.isDerivedAudioFile(url) }
            return FileStore.supportedDocumentExtensions.contains(ext)
        }
        // A PDF's first-page render `{base}.heic` is not a note of its own.
        let primaryBases = Set(notes.filter { FileStore.previewImageSessionBase($0) == nil }
            .map { $0.deletingPathExtension().lastPathComponent })
        return notes.filter { url in
            guard let base = FileStore.previewImageSessionBase(url) else { return true }
            return !primaryBases.contains(base)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// File names from a trash move log: a JSON list of `[from, to]` pairs.
    public static func trashedNames(fromLog url: URL) throws -> Set<String> {
        let data = try Data(contentsOf: url)
        guard let pairs = try JSONSerialization.jsonObject(with: data) as? [[String]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Set(pairs.compactMap { $0.last.map { URL(fileURLWithPath: $0).lastPathComponent } })
    }

    public static func plan(
        trashDirectory: URL = FileStore.trashDirectory(),
        recordingsDirectory: URL = FileStore.recordingsDirectory(),
        ledger: RecordingSyncState,
        onlyNames: Set<String>? = nil
    ) -> Plan {
        var plan = Plan()
        let alive = liveSyncIDs(in: recordingsDirectory)
        var seen = Set<String>()
        for url in trashedNotes(in: trashDirectory) {
            plan.scanned += 1
            if let onlyNames, !onlyNames.contains(url.lastPathComponent) {
                plan.skipped[.notInLog, default: []].append(url)
                continue
            }
            guard let syncId = RecordingSyncMetadata.readExplicitSyncID(for: url) else {
                plan.skipped[.noSyncId, default: []].append(url)
                continue
            }
            if alive.contains(syncId.rawValue) {
                plan.skipped[.aliveInRecordings, default: []].append(url)
                continue
            }
            guard seen.insert(syncId.rawValue).inserted else { continue }
            let entry = ledger.entries[syncId.rawValue]
            if entry?.status == .pendingDelete {
                plan.skipped[.alreadyPending, default: []].append(url)
                continue
            }
            plan.items.append(Item(
                trashedURL: url,
                syncId: syncId,
                originalURL: originalURL(of: url, recordingsDirectory: recordingsDirectory),
                ledgerStatus: entry?.status
            ))
        }
        return plan
    }

    /// The sidecar's `originalPath` (written by Trash moves) when it points
    /// into Recordings, else the same name in Recordings.
    static func originalURL(of trashedURL: URL, recordingsDirectory: URL) -> URL {
        let metaURL = FileStore.metadataURL(forRecordingURL: trashedURL)
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = json["originalPath"] as? String, !raw.isEmpty {
            let original = URL(fileURLWithPath: raw)
            if original.deletingLastPathComponent().standardizedFileURL.path
                == recordingsDirectory.standardizedFileURL.path {
                return original
            }
        }
        return recordingsDirectory.appendingPathComponent(trashedURL.lastPathComponent)
    }

    static func liveSyncIDs(in recordingsDirectory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var ids = Set<String>()
        for url in files where !url.lastPathComponent.hasSuffix(".json") && !FileStore.isDerivedAudioFile(url) {
            if let syncId = RecordingSyncMetadata.readSyncID(for: url) { ids.insert(syncId.rawValue) }
        }
        return ids
    }
}
