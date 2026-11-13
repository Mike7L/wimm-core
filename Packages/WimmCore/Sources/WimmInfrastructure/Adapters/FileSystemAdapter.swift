import Foundation
import CryptoKit
import WimmDomain

public actor FileSystemAdapter: StoragePort {
    private let fileManager = FileManager.default
    nonisolated private let rootDirectory: URL
    private var noteMetaURLByID: [UUID: URL] = [:]


    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public func loadAll() async throws -> [CapturedNote] {
        try ensureRootDirectory()
        let files = sidecarFiles()

        let parsed: [(CapturedNote, URL)] = await withTaskGroup(of: (CapturedNote, URL)?.self) { group in
            for url in files {
                group.addTask {
                    guard let data = try? Data(contentsOf: url),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let note = self.noteFromSidecar(dict: dict, metaURL: url)
                    else {
                        return nil
                    }
                    return (note, url)
                }
            }

            var results: [(CapturedNote, URL)] = []
            for await item in group {
                if let item = item {
                    results.append(item)
                }
            }
            return results
        }

        var notes: [CapturedNote] = []
        for (note, url) in parsed {
            noteMetaURLByID[note.id] = url
            notes.append(note)
        }

        return notes.sorted { $0.createdAt > $1.createdAt }
    }

    public func saveRecording(data: Data, fileName: String, initialText: String) async throws
        -> CapturedNote
    {
        try ensureRootDirectory()

        let audioURL = try makeUniqueAudioURL(from: fileName)
        try data.write(to: audioURL, options: .atomic)

        let note = CapturedNote(
            id: UUID(),
            createdAt: Date(),
            text: initialText,
            audioPath: audioURL.lastPathComponent,
            status: .pendingAnalysis
        )

        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("meta.json")
        noteMetaURLByID[note.id] = sidecarURL
        try writeMergedSidecar(note: note, to: sidecarURL)
        return note
    }

    public func deleteNote(id: UUID) async throws {
        // Fast path: resolve from the in-memory URL cache (populated by loadAll).
        // Avoids a full directory scan when the caller already called loadAll().
        let note: CapturedNote
        let metaURL: URL
        if let cached = noteMetaURLByID[id],
            let data = try? Data(contentsOf: cached),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let found = noteFromSidecar(dict: dict, metaURL: cached)
        {
            note = found
            metaURL = cached
        } else {
            // Cold path: full directory scan (first call without prior loadAll).
            let all = try await loadAll()
            guard let found = all.first(where: { $0.id == id }) else {
                throw StorageError.noteNotFound(id.uuidString)
            }
            note = found
            metaURL = noteMetaURLByID[id] ?? sidecarURL(for: note)
        }
        if let audioPath = note.audioPath {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(audioPath))
        }
        try? fileManager.removeItem(at: metaURL)
        noteMetaURLByID.removeValue(forKey: id)
    }

    public func updateNote(_ note: CapturedNote) async throws {
        try ensureRootDirectory()
        let url = noteMetaURLByID[note.id] ?? sidecarURL(for: note)
        noteMetaURLByID[note.id] = url
        try writeMergedSidecar(note: note, to: url)
    }

    public func loadNote(matchingAudioPath audioPath: String) async throws -> CapturedNote? {
        let all = try await loadAll()
        let targetName = URL(fileURLWithPath: audioPath).lastPathComponent
        let targetStem = URL(fileURLWithPath: targetName).deletingPathExtension().lastPathComponent
        return all.first { note in
            guard let path = note.audioPath else { return false }
            let noteName = URL(fileURLWithPath: path).lastPathComponent
            let noteStem = URL(fileURLWithPath: noteName).deletingPathExtension().lastPathComponent
            return noteName == targetName || noteStem == targetStem
        }
    }

    private func writeMergedSidecar(note: CapturedNote, to sidecarURL: URL) throws {
        try FileStore.mutateSidecar(at: sidecarURL) { merged in
            merged["id"] = note.id.uuidString
            merged["createdAt"] = ISO8601.string(from: note.createdAt)
            merged["text"] = note.text
            merged["audioPath"] = note.audioPath
            merged["wimmStatus"] = statusString(note.status)
            merged.removeValue(forKey: Self.legacyStatusKey)

            if let audioPath = note.audioPath, isAudioPath(audioPath) {
                let trimmedText = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    var transcription = merged["transcription"] as? [String: Any] ?? [:]
                    transcription["transcript"] = note.text
                    transcription["speechStatus"] = TranscriptionSpeechStatus.speech.rawValue
                    merged["transcription"] = transcription
                    merged.removeValue(forKey: "transcriptionFailure")
                    merged.removeValue(forKey: "transcriptionFailureDetails")
                }
            }

            if case .failed(let reason, let retryable) = note.status {
                merged["wimmErrorReason"] = reason
                merged["wimmRetryable"] = retryable
            } else {
                merged.removeValue(forKey: "wimmErrorReason")
                merged.removeValue(forKey: "wimmRetryable")
            }
            merged.removeValue(forKey: Self.legacyErrorReasonKey)
            merged.removeValue(forKey: Self.legacyRetryableKey)

            if let title = note.title {
                merged["title"] = title
            }

            if let card = note.card {
                merged["noteCard"] = [
                    "title": card.title,
                    "summary": card.summary,
                    "tags": card.tags,
                    "projects": card.projects,
                    "is_artifact": card.isArtifact,
                    "is_draft": card.isDraft,
                    "is_insight": card.isInsight,
                    "is_liked": card.isLiked,
                ]
            }

            return true
        }
    }

    nonisolated private func noteFromSidecar(dict: [String: Any], metaURL: URL) -> CapturedNote? {
        let id = parseID(from: dict, metaURL: metaURL)
        let createdAt = parseDate(from: dict)
            ?? inferCreatedAt(from: metaURL)
            ?? Date(timeIntervalSince1970: 0)
        let text = parseText(from: dict)
        let card = parseNoteCard(from: dict)

        let audioPath = (dict["audioPath"] as? String) ?? inferAudioPath(metaURL: metaURL)
        let status = parseStatus(from: dict, card: card, text: text)
        let title = dict["title"] as? String

        var note = CapturedNote(
            id: id, createdAt: createdAt, text: text, audioPath: audioPath, status: status)
        note.title = title
        note.card = card
        return note
    }

    nonisolated private func isAudioPath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "m4a", "caf", "wav", "mp3", "mp4", "aac", "opus", "flac":
            return true
        default:
            return false
        }
    }

    nonisolated private func parseID(from dict: [String: Any], metaURL: URL) -> UUID {
        if let value = dict["id"] as? String, let uuid = UUID(uuidString: value) {
            return uuid
        }

        let stem = metaURL.lastPathComponent
            .replacingOccurrences(of: ".meta.json", with: "")
            .replacingOccurrences(of: ".metadata.json", with: "")
        if let uuid = UUID(uuidString: stem) {
            return uuid
        }

        return stableUUID(from: metaURL.path)
    }

    nonisolated private func stableUUID(from value: String) -> UUID {
        let digest = SHA256.hash(data: Data(value.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    nonisolated private func parseDate(from dict: [String: Any]) -> Date? {
        let candidates = ["createdAt", "created_at", "date"]
        for key in candidates {
            guard let value = dict[key] as? String else { continue }
            if let date = ISO8601.date(from: value) {
                return date
            }
        }
        return nil
    }

    nonisolated private func inferCreatedAt(from metaURL: URL) -> Date? {
        if let values = try? metaURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
            return values.creationDate ?? values.contentModificationDate
        }
        return nil
    }

    nonisolated private func parseText(from dict: [String: Any]) -> String {
        let candidates: [String?] = [
            dict["refinedText"] as? String,
            dict["text"] as? String,
            (dict["transcription"] as? [String: Any])?["transcript"] as? String,
            (dict["transcription"] as? [String: Any])?["text"] as? String,
            (dict["noteCard"] as? [String: Any])?["refined_text"] as? String,
        ]
        return candidates.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    nonisolated private func parseNoteCard(from dict: [String: Any]) -> AnalysisCard? {
        guard let noteCard = dict["noteCard"] as? [String: Any] else {
            return nil
        }

        // Reads a Bool flag from a JSON dict, defaulting to false when absent.
        func boolFlag(_ key: String) -> Bool { (noteCard[key] as? Bool) ?? false }

        let title = (noteCard["title"] as? String) ?? "Untitled"
        let summary = (noteCard["summary"] as? String) ?? ""
        let tags = (noteCard["tags"] as? [String]) ?? []
        let projects = (noteCard["projects"] as? [String]) ?? []
        // Read WimmCoreMinimal-compatible boolean flags from .meta.json
        let isArtifact = boolFlag("is_artifact")
        let isDraft = boolFlag("is_draft")
        let isInsight = boolFlag("is_insight")
        let isLiked = boolFlag("is_liked")
        return AnalysisCard(
            title: title,
            summary: summary,
            tags: tags,
            projects: projects,
            isArtifact: isArtifact,
            isDraft: isDraft,
            isInsight: isInsight,
            isLiked: isLiked
        )
    }

    private static let legacyStatusKey = "mem" + "arioStatus"
    private static let legacyErrorReasonKey = "mem" + "arioErrorReason"
    private static let legacyRetryableKey = "mem" + "arioRetryable"

    nonisolated private func parseStatus(from dict: [String: Any], card: AnalysisCard?, text: String)
        -> ProcessingStatus
    {
        if card != nil {
            return .completed
        }

        if let value = (dict["wimmStatus"] as? String) ?? (dict[Self.legacyStatusKey] as? String) {
            switch value {
            case "completed": return .completed
            case "pending_analysis": return .pendingAnalysis
            case "failed":
                let retryable = (dict["wimmRetryable"] as? Bool) ?? (dict[Self.legacyRetryableKey] as? Bool) ?? false
                return .failed(
                    reason: (dict["wimmErrorReason"] as? String) ?? (dict[Self.legacyErrorReasonKey] as? String) ?? "failed",
                    retryable: retryable
                )
            default:
                break
            }
        }

        if let value = dict["status"] as? String, value == "failed" {
            return .failed(reason: "legacy_failed", retryable: false)
        }

        if !text.isEmpty {
            return .pendingAnalysis
        }

        return .failed(reason: "missing_text", retryable: false)
    }

    nonisolated private func inferAudioPath(metaURL: URL) -> String? {
        let stem = metaURL.lastPathComponent
            .replacingOccurrences(of: ".meta.json", with: "")
            .replacingOccurrences(of: ".metadata.json", with: "")
        let siblingDir = metaURL.deletingLastPathComponent()
        for ext in ["m4a", "wav", "mp3"] {
            let name = "\(stem).\(ext)"
            for dir in [siblingDir, recordingsDirectory(), rootDirectory] {
                let candidate = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate.lastPathComponent
                }
            }
        }
        return nil
    }

    /// Resolves the canonical `.meta.json` URL for a note, using its audioPath if present.
    nonisolated private func sidecarURL(for note: CapturedNote) -> URL {
        if let audioPath = note.audioPath {
            return recordingsDirectory()
                .appendingPathComponent(audioPath)
                .deletingPathExtension()
                .appendingPathExtension("meta.json")
        }
        return recordingsDirectory()
            .appendingPathComponent("\(note.id.uuidString).meta.json")
    }


    nonisolated private func isSidecar(url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasSuffix(".meta.json") || name.hasSuffix(".metadata.json")
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: recordingsDirectory(), withIntermediateDirectories: true)
    }

    private func makeUniqueAudioURL(from fileName: String) throws -> URL {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = trimmed.isEmpty ? "recording.m4a" : trimmed
        let hasExtension = URL(fileURLWithPath: requested).pathExtension.isEmpty == false
        let normalized = hasExtension ? requested : "\(requested).m4a"

        var candidate = recordingsDirectory().appendingPathComponent(normalized)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }

        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        candidate = recordingsDirectory().appendingPathComponent(
            "\(base)_\(UUID().uuidString.prefix(6)).\(ext)")
        return candidate
    }

    nonisolated private func recordingsDirectory() -> URL {
        rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    nonisolated private func sidecarFiles() -> [URL] {
        var sidecars: [URL] = []
        
        // 1. Scan rootDirectory (non-recursively)
        if let rootFiles = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            sidecars.append(contentsOf: rootFiles.filter { isSidecar(url: $0) })
        }
        
        // 2. Scan recordingsDirectory() (non-recursively)
        let recordingsDir = recordingsDirectory()
        if let recordingsFiles = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            sidecars.append(contentsOf: recordingsFiles.filter { isSidecar(url: $0) })
        }
        
        return sidecars
    }

    private func statusString(_ status: ProcessingStatus) -> String {
        switch status {
        case .completed: return "completed"
        case .pendingAnalysis: return "pending_analysis"
        case .failed: return "failed"
        }
    }
}
