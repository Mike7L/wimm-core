import Foundation
import os
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// Where a recording's sync identity lives in its sidecar, and how this
// device names itself.

public enum RecordingSyncMetadata {
    public static let syncIdKey = "syncId"
    public static let syncUpdatedAtKey = "syncUpdatedAt"

    public static func readSyncID(for recordingURL: URL) -> SyncRecordingID? {
        let metaURL = FileStore.metadataURL(forRecordingURL: recordingURL)
        // Every sync pass asks this for every note in the ledger. Parsing each sidecar
        // (some hold megabytes of text) cost hundreds of MB per pass; an unchanged file
        // answers from its stamp instead.
        let stamp = SidecarStamp(path: metaURL.path)
        if let stamp, let cached = syncIDCache.withLock({ $0[metaURL.path] }), cached.stamp == stamp {
            return cached.raw.map { SyncRecordingID(rawValue: $0) }
        }
        guard let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let found = (json[syncIdKey] as? String)
            ?? (json[RecordingIdentity.metadataKey] as? String)
        let raw = found.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        // Only when the file did not change while it was being read.
        if let stamp, SidecarStamp(path: metaURL.path) == stamp {
            syncIDCache.withLock { $0[metaURL.path] = (stamp, raw) }
        }
        return raw.map { SyncRecordingID(rawValue: $0) }
    }

    private struct SidecarStamp: Equatable, Sendable {
        let inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int
        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino); size = Int64(info.st_size)
            seconds = Int(info.st_mtimespec.tv_sec); nanoseconds = Int(info.st_mtimespec.tv_nsec)
        }
    }

    private static let syncIDCache = OSAllocatedUnfairLock<[String: (stamp: SidecarStamp, raw: String?)]>(initialState: [:])

    /// Only the `syncId` key, without the note-id fallback: a note that was
    /// never synced has a note id but no record in the cloud to delete.
    public static func readExplicitSyncID(for recordingURL: URL) -> SyncRecordingID? {
        let metaURL = FileStore.metadataURL(forRecordingURL: recordingURL)
        guard let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json[syncIdKey] as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return SyncRecordingID(rawValue: raw)
    }

    @discardableResult
    public static func ensureSyncID(for recordingURL: URL, now: Date = Date()) throws -> SyncRecordingID {
        if let existing = readSyncID(for: recordingURL) {
            try setSyncID(existing, for: recordingURL, now: now)
            return existing
        }

        let syncId = SyncRecordingID()
        try setSyncID(syncId, for: recordingURL, now: now)
        return syncId
    }

    public static func setSyncID(
        _ syncId: SyncRecordingID,
        for recordingURL: URL,
        now: Date = Date()
    ) throws {
        let metaURL = FileStore.metadataURL(forRecordingURL: recordingURL)
        try FileManager.default.createDirectory(at: metaURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Under the shared sidecar lock: CloudSync enqueues a recording in the
        // same moments transcription and NoteOrigin are writing its sidecar.
        try FileStore.mutateSidecar(at: metaURL) { current in
            current[syncIdKey] = syncId.rawValue
            current[syncUpdatedAtKey] = wimmSyncDateString(now)
            if current[RecordingIdentity.metadataKey] == nil,
               UUID(uuidString: syncId.rawValue) != nil {
                current[RecordingIdentity.metadataKey] = syncId.rawValue
            }
            return true
        }
    }
}

public enum RecordingSyncDeviceIdentity {
    public static func currentDeviceID() -> String {
        let url = FileStore.baseDirectory()
            .appendingPathComponent("sync", isDirectory: true)
            .appendingPathComponent("device_id.txt")
        if let existing = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }
}
