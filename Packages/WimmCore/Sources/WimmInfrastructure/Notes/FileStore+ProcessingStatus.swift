import Foundation
import WimmDomain

// The processing-status edge of `FileStore`. It lives here rather than in
// WimmDomain because it reads `MetadataKey` and `LegacyProcessingStatus`,
// both of which are infrastructure concerns — the domain type must not learn
// about the sidecar schema.

extension FileStore {

    public static func getProcessingStatus(for recordingURL: URL) -> LegacyProcessingStatus {
        let metaURL = metadataURL(forRecordingURL: recordingURL)
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let statusStr = json["processingStatus"] as? String,
           let status = LegacyProcessingStatus(rawValue: statusStr) {
            return status
        }
        return .pending
    }

    /// One-time data migration helper:
    /// Converts `processingStatus: null` to `processingStatus: "completed"` for text notes.
    /// This prevents legacy entries from being treated as pending forever on startup.
    @discardableResult
    public static func migrateNullProcessingStatusToCompletedForTextNotes() -> Int {
        let fm = FileManager.default
        let recordingsDir = recordingsDirectory()
        guard let enumerator = fm.enumerator(
            at: recordingsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var migrated = 0
        while let item = enumerator.nextObject() {
            guard let url = item as? URL else { continue }
            guard url.pathExtension.lowercased() == "txt" else { continue }

            let metaURL = metadataURL(forRecordingURL: url)
            guard FileManager.default.fileExists(atPath: metaURL.path) else { continue }

            // Runs at startup, while the journal build and any in-flight
            // transcription may be writing the same sidecars.
            var didMigrate = false
            do {
                try mutateSidecar(at: metaURL) { json in
                    guard json[MetadataKey.processingStatus.rawValue] is NSNull else { return false }
                    json[MetadataKey.processingStatus.rawValue] = LegacyProcessingStatus.completed.rawValue
                    didMigrate = true
                    return true
                }
            } catch {
                continue  // only a successful write counts as migrated
            }
            if didMigrate { migrated += 1 }
        }
        return migrated
    }
}
