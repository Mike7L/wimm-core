import Foundation
import WimmDomain

/// Agent-authored Markdown enters the ordinary library without a model call.
enum MarkdownNoteCapture {
    static func save(title: String, markdown: String, directory: URL, date: Date) throws -> URL {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure("title and markdown must be non-empty")
        }
        guard title.utf8.count <= 1_000, markdown.utf8.count <= 1_000_000 else {
            throw Failure("title exceeds 1,000 bytes or markdown exceeds 1,000,000 bytes")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = RecordingIdentity(createdAt: date)
        var file = directory.appendingPathComponent(identity.fileName(extension: "md", idLength: 32))
        try Data(markdown.utf8).write(to: file, options: .withoutOverwriting)
        do {
            // Use the same URL spelling as FileRepository's listing. Foundation
            // can spell /var differently here even after resolving symlinks;
            // recall ids are path-based, so the returned id must match the reader.
            file = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.lastPathComponent == file.lastPathComponent } ?? file
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
                metadata[RecordingIdentity.metadataKey] = identity.id.uuidString
                metadata[RecordingIdentity.createdAtMetadataKey] = ISO8601.string(from: date)
                metadata["title"] = title
                metadata["origin"] = ["source": "agent-discussion"]
                // The file is the body (NoteContent); a second copy here would go stale.
                metadata["document"] = ["title": title]
                return true
            }
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
