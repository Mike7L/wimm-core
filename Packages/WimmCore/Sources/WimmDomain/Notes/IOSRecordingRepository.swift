import Foundation

/// iOS-specific facade for recording operations.
/// Provides minimal API needed by iOS, isolating it from full WimmCore.
///
/// Implementation notes:
/// - recordings() logic copied from FileRepository
/// - existingNoteCard() logic copied from MetadataRepository
/// - attachments() logic copied from AttachmentRepository
/// - Maintains .meta.json format compatibility with macOS
public actor IOSRecordingRepository {
    
    public enum Order { case ascending, descending }
    public static let shared = IOSRecordingRepository()
    
    private let fileManager = FileManager.default
    
    public init() {}
    
    // MARK: - Recordings Listing
    
    /// Cache for recordings list to avoid repeated filesystem scans
    private var cachedRecordings: [URL]?
    private var cacheTimestamp: Date?
    private let cacheValidityDuration: TimeInterval = 1.0  // 1 second cache
    
    public func recordings(order: Order = .ascending, limit: Int? = nil) -> [URL] {
        var list = listRecordingsAscending()
        if order == .descending { list = Array(list.reversed()) }
        if let limit, limit < list.count { return Array(list.prefix(limit)) }
        return list
    }
    
    /// Thread-safe implementation of recordings listing
    private func listRecordingsAscending() -> [URL] {
        // Check cache validity
        if let cached = cachedRecordings,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidityDuration {
            return cached
        }
        
        let primaryDir = FileStore.recordingsDirectory()
        // Note: iOS typically doesn't have "legacy" dir structure like macOS migration, 
        // but we keep consistent with WimmCore logic if needed. 
        // For minimal iOS repo, we just check recordingsDirectory.
        
        let all = (try? fileManager.contentsOfDirectory(at: primaryDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        
        // Filter to supported files: audio (skip generated _mini/_micro) and documents
        let filtered = all.filter { url in
            let ext = url.pathExtension.lowercased()
            if FileStore.supportedAudioExtensions.contains(ext) {
                return !FileStore.isDerivedAudioFile(url)
            }
            return FileStore.supportedDocumentExtensions.contains(ext)
        }
        
        // Deduplicate and sort
        let sorted = filtered.sorted {
            let a = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return a < b
        }
        
        cachedRecordings = sorted
        cacheTimestamp = Date()
        return sorted
    }
    
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
            print("IOSRecordingRepository: Decoding failed for \(file.lastPathComponent): \(error)")
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
        var legacyFieldsDetected = false

        for dict in list {
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr),
                  let type = dict["type"] as? String else { continue }

            if dict["ocrText"] != nil || dict["ocrProvider"] != nil || dict["ocrModel"] != nil {
                legacyFieldsDetected = true
            }

            decoded.append(NoteAttachment(
                id: id,
                url: url,
                type: type,
                extractedText: dict["extractedText"] as? String ?? dict["ocrText"] as? String,
                extractionProvider: dict["extractionProvider"] as? String ?? dict["ocrProvider"] as? String,
                extractionModel: dict["extractionModel"] as? String ?? dict["ocrModel"] as? String
            ))
        }

        // Opportunistic migration: rewrite legacy attachment keys to extracted*.
        if legacyFieldsDetected {
            upsertAttachments(for: file, attachments: decoded)
        }

        return decoded
    }
    
    public func upsertAttachments(for file: URL, attachments: [NoteAttachment]) {
        let existingList = metadata(for: file)["attachments"] as? [[String: Any]] ?? []
        let jsonCompatible = attachments.map { attachment -> [String: Any] in
            let idString = attachment.id.uuidString
            let urlString = attachment.url.absoluteString
            var dict = existingList.first(where: {
                ($0["id"] as? String) == idString || ($0["url"] as? String) == urlString
            }) ?? [:]

            if let extracted = attachment.extractedText {
                let prior = ((dict["extractedText"] as? String) ?? (dict["ocrText"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let next = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
                if !prior.isEmpty, prior != "[[NO_SPEECH]]", prior != next {
                    var entry: [String: Any] = [
                        "text": prior,
                        "replacedAt": ISO8601.string(from: Date())
                    ]
                    if let p = (dict["extractionProvider"] as? String) ?? (dict["ocrProvider"] as? String), !p.isEmpty {
                        entry["provider"] = p
                    }
                    if let m = (dict["extractionModel"] as? String) ?? (dict["ocrModel"] as? String), !m.isEmpty {
                        entry["model"] = m
                    }
                    if let s = dict["startedAt"] as? String, !s.isEmpty {
                        entry["startedAt"] = s
                    }
                    var runs = dict["previousRuns"] as? [[String: Any]] ?? []
                    runs.append(entry)
                    if runs.count > 8 { runs.removeFirst(runs.count - 8) }
                    dict["previousRuns"] = runs
                }
                dict["extractedText"] = extracted
            }
            dict["id"] = idString
            dict["url"] = urlString
            dict["type"] = attachment.type
            if let provider = attachment.extractionProvider { dict["extractionProvider"] = provider }
            if let model = attachment.extractionModel { dict["extractionModel"] = model }
            for legacy in ["ocrText", "ocrProvider", "ocrModel"] { dict.removeValue(forKey: legacy) }
            return dict
        }
        upsertMetadata(file: file, updates: ["attachments": jsonCompatible])
    }
    
    public func appendAttachments(for file: URL, attachments newAttachments: [NoteAttachment]) {
        let current = attachments(for: file)
        upsertAttachments(for: file, attachments: current + newAttachments)
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
    
    /// Finds all incomplete recordings in the recordings directory
    public func findIncompleteRecordings() async -> [URL] {
        let allRecordings = recordings()
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
                print("IOSRecordingRepository: Failed to load metadata for \(recordingURL.lastPathComponent): \(error)")
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

    /// Call after creating a note so an immediate reload includes it.
    public func invalidateCache() {
        cachedRecordings = nil
        cacheTimestamp = nil
    }

    public func moveToTrash(file: URL) -> URL? {
        let trashedURL = RecordingTrashSupport.moveToTrash(
            file: file,
            fileManager: fileManager,
            onFailure: { sourceURL, error in
                print("[IOSRecordingRepository] Failed to move \(sourceURL.lastPathComponent) to trash: \(error)")
            }
        )
        invalidateCache()
        return trashedURL
    }
}
