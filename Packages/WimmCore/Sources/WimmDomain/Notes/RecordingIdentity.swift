import Foundation

/// Stable identity allocated before a recording starts.
///
/// The filename is a human-readable label. `id` is the durable identity used by
/// metadata and sync; only a short prefix is included in the normal filename.
public struct RecordingIdentity: Codable, Hashable, Sendable {
    public static let metadataKey = "recordingId"
    public static let createdAtMetadataKey = "createdAt"

    public let id: UUID
    public let createdAt: Date

    public init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.createdAt = createdAt
    }

    public var compactID: String {
        id.uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    public var shortID: String {
        String(compactID.prefix(8))
    }

    /// The stamp carries seconds on purpose: `FileRepository` orders the
    /// library by filename and treats that order as chronological. Truncated to
    /// the minute, everything captured inside the same minute fell back to
    /// sorting by the random id suffix — a shorter name bought at the price of
    /// putting notes in the wrong order.
    public func fileName(
        extension fileExtension: String = "m4a",
        idLength: Int = 8,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let length = min(max(idLength, 8), compactID.count)
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let base = "Wimm_\(formatter.string(from: createdAt))_\(compactID.prefix(length))"
        return ext.isEmpty ? base : "\(base).\(ext)"
    }

    /// Seeds the adjacent sidecar before capture begins. Later metadata writes
    /// merge with this payload, so the full identity survives recording,
    /// transcription, and CloudKit enqueueing.
    public func persist(for recordingURL: URL) {
        FileStore.upsertMetadata(
            for: recordingURL,
            updates: [
                Self.metadataKey: id.uuidString,
                Self.createdAtMetadataKey: ISO8601.string(from: createdAt),
            ]
        )
    }
}
