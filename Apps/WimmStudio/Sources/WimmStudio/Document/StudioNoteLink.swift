import Foundation
import WimmDomain
import WimmInfrastructure

enum StudioNoteLink {
    /// Resolve by full path, not basename: an unrelated file can share a note's name.
    static func resolve(_ url: URL, in index: [String: StudioLibraryNote]) -> StudioLibraryNote? {
        guard url.isFileURL else { return nil }
        return index[URL(fileURLWithPath: url.path).standardizedFileURL.path]
    }

    static func index(_ notes: [StudioLibraryNote]) -> [String: StudioLibraryNote] {
        var result: [String: StudioLibraryNote] = [:]
        for note in notes {
            result[note.fileURL.standardizedFileURL.path] = note
            let metadata = note.metadataURL ?? FileStore.metadataURL(forRecordingURL: note.fileURL)
            result[metadata.standardizedFileURL.path] = note
        }
        return result
    }

    static func referenceURL(_ via: String) -> URL? {
        guard let prefix = ["note:", "voice:"].first(where: { via.hasPrefix($0) }) else { return nil }
        let raw = String(via.dropFirst(prefix.count)).components(separatedBy: "#")[0]
        return NoteAttachmentMedia.resolve(raw)
    }
}
