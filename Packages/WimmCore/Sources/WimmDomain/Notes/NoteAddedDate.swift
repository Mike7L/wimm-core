import Foundation

/// When a note was added to the library, as opposed to its date: an imported
/// photo or video is dated by when it was shot (the file name carries that),
/// and the sidecar's `addedAt` keeps the moment of the import next to it.
public enum NoteAddedDate {
    public static let metadataKey = "addedAt"

    /// Merges via upsert; safe to call repeatedly.
    public static func stamp(_ recordingURL: URL, at date: Date = Date()) {
        FileStore.upsertMetadata(for: recordingURL, updates: [metadataKey: ISO8601.string(from: date)])
    }

    /// The import moment of a sidecar: `addedAt`, else what older writers
    /// stored (`origin.addedAt` of evening photos, `shareSource.sharedAt`).
    public static func read(metadata: [String: Any]) -> Date? {
        let candidates: [Any?] = [
            metadata[metadataKey],
            (metadata["origin"] as? [String: Any])?["addedAt"],
            (metadata[NoteShareSource.metadataKey] as? [String: Any])?["sharedAt"],
        ]
        return candidates.lazy.compactMap { ($0 as? String).flatMap(ISO8601.date(from:)) }.first
    }
}
