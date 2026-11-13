import Foundation

/// Metadata for tracking recordings in progress.
/// Allows recovery of incomplete recordings after crashes.
public struct RecordingMetadata: Codable {
    /// Durable identity allocated before capture starts.
    public var recordingID: UUID?

    /// Path to the audio file
    public let recordingURL: URL
    
    /// Current transcription text
    public var transcription: String
    
    /// Duration in seconds at the time of save
    public var duration: TimeInterval
    
    /// Timestamp when recording was created
    public let timestamp: Date
    
    /// Whether recording has been completed
    public var isComplete: Bool
    
    /// Timestamp of last metadata save
    public var lastSaved: Date
    
    public init(
        recordingURL: URL,
        recordingID: UUID? = nil,
        transcription: String = "",
        duration: TimeInterval = 0,
        timestamp: Date = Date(),
        isComplete: Bool = false,
        lastSaved: Date = Date()
    ) {
        self.recordingURL = recordingURL
        self.recordingID = recordingID
        self.transcription = transcription
        self.duration = duration
        self.timestamp = timestamp
        self.isComplete = isComplete
        self.lastSaved = lastSaved
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case recordingURL, recordingID = "recordingId", transcription, duration, timestamp, isComplete, lastSaved
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Handle URL decoding - support both absolute and relative paths
        let urlString = try container.decode(String.self, forKey: .recordingURL)
        if let url = URL(string: urlString), url.scheme != nil {
            recordingURL = url
        } else {
            // Fallback: treat as relative path
            recordingURL = FileStore.resolveRelativePath(urlString)
        }
        recordingID = try container.decodeIfPresent(UUID.self, forKey: .recordingID)
        
        // The recorder writes a plain string; once a file run has transcribed
        // the note the same key is a dictionary. Read either.
        if let text = try? container.decode(String.self, forKey: .transcription) {
            transcription = text
        } else {
            let run = try? container.decode(TranscriptionObject.self, forKey: .transcription)
            transcription = run?.transcript ?? run?.localTranscript ?? ""
        }
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isComplete = try container.decode(Bool.self, forKey: .isComplete)
        lastSaved = try container.decode(Date.self, forKey: .lastSaved)
    }
    
    private struct TranscriptionObject: Decodable {
        let transcript: String?
        let localTranscript: String?
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Store as relative path for portability
        try container.encode(FileStore.relativePath(for: recordingURL), forKey: .recordingURL)
        try container.encodeIfPresent(recordingID, forKey: .recordingID)
        try container.encode(transcription, forKey: .transcription)
        try container.encode(duration, forKey: .duration)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isComplete, forKey: .isComplete)
        try container.encode(lastSaved, forKey: .lastSaved)
    }
}

// MARK: - Metadata File Helpers

extension RecordingMetadata {
    /// Returns the URL where metadata should be saved for a given recording
    public static func metadataURL(for recordingURL: URL) -> URL {
        recordingURL
            .deletingPathExtension()
            .appendingPathExtension("meta.json")
    }
    
    /// Returns the legacy URL (older format) for compatibility
    public static func legacyMetadataURL(for recordingURL: URL) -> URL {
        recordingURL
            .deletingPathExtension()
            .appendingPathExtension("metadata.json")
    }
    
    /// Loads metadata from disk for a given recording URL
    public static func load(for recordingURL: URL) throws -> RecordingMetadata {
        // Try new format first
        let url = metadataURL(for: recordingURL)
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(RecordingMetadata.self, from: data)
        }
        
        // Fallback to legacy format
        let legacyUrl = legacyMetadataURL(for: recordingURL)
        let data = try Data(contentsOf: legacyUrl)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(RecordingMetadata.self, from: data)
        try metadata.save()  // Migrate: write meta.json + legacy
        return metadata
    }
    
    /// Saves metadata to disk
    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let ownData = try encoder.encode(self)
        guard let ownKeys = try JSONSerialization.jsonObject(with: ownData) as? [String: Any] else {
            throw CocoaError(.fileWriteUnknown)
        }

        // The .meta.json sidecar also carries keys owned by other writers
        // (noteCard, origin, attachments, syncId…), so merge ours in — under the
        // shared sidecar lock, like every other writer.
        try FileStore.mutateSidecar(at: Self.metadataURL(for: recordingURL)) { current in
            for (key, value) in ownKeys {
                // A dictionary `transcription` holds file runs and the realtime
                // text (`TranscriptKind`); our plain string must not replace it.
                if key == CodingKeys.transcription.rawValue, current[key] is [String: Any] { continue }
                current[key] = value
            }
            return true
        }

        // The legacy .metadata.json copy is ours alone and gets only our keys.
        // bf046dc (2026-07-27) added the merge above and reused the name `data`
        // for the merged bytes, which silently turned this write into a full
        // clone of the shared sidecar — foreign keys included, frozen at the
        // moment of the last save.
        try ownData.write(to: Self.legacyMetadataURL(for: recordingURL), options: .atomic)
    }
}
