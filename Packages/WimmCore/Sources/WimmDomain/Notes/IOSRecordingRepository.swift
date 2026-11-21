import Foundation

/// iOS-specific facade for sidecar reads and the few writes the app makes.
/// The note list comes from `FileRepository` (same listing rules as the Mac);
/// every sidecar write goes through `FileStore.mutateSidecar`.
///
/// Implementation notes:
/// - existingNoteCard() logic copied from MetadataRepository
/// - attachments() reads legacy entries (one note = one media: new code
///   never writes `attachments`)
public actor IOSRecordingRepository {
    
    public static let shared = IOSRecordingRepository()
    
    private let fileManager = FileManager.default
    
    public init() {}
    
    // MARK: - NoteCards & Metadata
    
    public func existingNoteCard(for file: URL) -> NoteCard? {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        
        do {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nc = obj["noteCard"] as? [String: Any] else {
                return nil
            }
            
            let json = try JSONSerialization.data(withJSONObject: nc)
            return try JSONDecoder().decode(NoteCard.self, from: json)
        } catch {
            log("IOSRecordingRepository: Decoding failed for \(file.lastPathComponent): \(error)")
            return nil
        }
    }
    
    public func upsertNoteCard(for file: URL, card: NoteCard, lang: String?) {
        var updates: [String: Any] = [:]
        
        var cardDict: [String: Any]?
        if let data = try? JSONEncoder().encode(card),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cardDict = dict
        }
        
        if let cardDict {
            updates["noteCard"] = cardDict
        }
        if let lang {
            updates["language"] = lang
        }
        
        upsertMetadata(file: file, updates: updates)
    }
    
    public func metadata(for file: URL) -> [String: Any] {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }
    
    /// Delegates to `FileStore.upsertMetadata`. This used to be a hand-copy of
    /// it ("simplified version") that dropped the sidecar lock — while
    /// `NoteOrigin.stamp` and `RecordingIdentity.persist` wrote the same file
    /// through the locked path, so on iOS the lock guarded one writer against
    /// itself and attachments/note-card writes could erase their keys.
    public func upsertMetadata(file: URL, updates: [String: Any]) {
        FileStore.upsertMetadata(for: file, updates: updates)
    }
    
    // MARK: - Attachments
    
    public func attachments(for file: URL) -> [NoteAttachment] {
        let meta = metadata(for: file)
        guard let list = meta["attachments"] as? [[String: Any]] else { return [] }
        var decoded: [NoteAttachment] = []

        for dict in list {
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr),
                  let type = dict["type"] as? String else { continue }

            decoded.append(NoteAttachment(
                id: id,
                url: url,
                type: type,
                extractedText: dict["extractedText"] as? String ?? dict["ocrText"] as? String,
                extractionProvider: dict["extractionProvider"] as? String ?? dict["ocrProvider"] as? String,
                extractionModel: dict["extractionModel"] as? String ?? dict["ocrModel"] as? String
            ))
        }

        return decoded
    }
    
    // MARK: - Recording Metadata Operations
    
    /// Saves recording metadata to a .metadata.json file next to the recording
    public func saveMetadata(for url: URL, metadata: RecordingMetadata) async throws {
        try metadata.save()
    }
    
    /// Loads recording metadata from the .metadata.json file
    public func loadMetadata(for url: URL) async throws -> RecordingMetadata {
        return try RecordingMetadata.load(for: url)
    }
    
    /// Finds all incomplete recordings in the recordings directory: every
    /// audio original (not the derived `_micro`/`_mini`), not the note list.
    public func findIncompleteRecordings() async -> [URL] {
        let directory = FileStore.recordingsDirectory()
        let allRecordings = ((try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { FileStore.isAudioFile($0) && !FileStore.isDerivedAudioFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var incompleteURLs: [URL] = []
        
        for recordingURL in allRecordings {
            // Check if metadata file exists
            let metadataURL = RecordingMetadata.metadataURL(for: recordingURL)
            guard fileManager.fileExists(atPath: metadataURL.path) else {
                continue
            }
            
            // Try to load metadata
            do {
                let metadata = try RecordingMetadata.load(for: recordingURL)
                if !metadata.isComplete {
                    incompleteURLs.append(recordingURL)
                }
            } catch {
                log("IOSRecordingRepository: Failed to load metadata for \(recordingURL.lastPathComponent): \(error)")
            }
        }
        
        return incompleteURLs
    }
    
    /// Marks a recording as complete by updating its metadata
    public func markAsComplete(_ url: URL) async throws {
        var metadata = try RecordingMetadata.load(for: url)
        metadata.isComplete = true
        metadata.lastSaved = Date()
        try metadata.save()
    }

    // MARK: - Trash Operations

    public func moveToTrash(file: URL) -> URL? {
        let trashedURL = RecordingTrashSupport.moveToTrash(
            file: file,
            fileManager: fileManager,
            onFailure: { sourceURL, error in
                log("[IOSRecordingRepository] Failed to move \(sourceURL.lastPathComponent) to trash: \(error)")
            }
        )
        return trashedURL
    }
}
