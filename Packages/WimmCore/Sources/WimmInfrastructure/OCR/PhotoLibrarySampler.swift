import Foundation
import ImageIO
import WimmDomain

/// Read-only, bounded selection of distinct image files, including note attachments.
/// Dates are capture dates when available; file creation dates are only a fallback.
public enum PhotoLibrarySampler {
    public struct Target: Sendable {
        public let note: URL
        public let image: URL
        public let date: Date
        public let dateBasis: String
    }

    public static func recent(limit: Int) async -> [Target] {
        guard limit > 0 else { return [] }
        let notes = await FileRepository().recordings(order: .descending)
        var candidates: [Target] = []
        for note in notes {
            let sidecar = FileStore.metadataURL(forRecordingURL: note)
            let root = (try? Data(contentsOf: sidecar)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let stamp: Date
            let basis: String
            if let date = FileStore.recordingDateFromFileName(note) {
                stamp = date; basis = "note_filename"
            } else if let number = root["timestamp"] as? Double, number > 0 {
                stamp = Date(timeIntervalSince1970: number); basis = "note_timestamp"
            } else {
                stamp = (try? note.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                basis = "file_creation_fallback"
            }
            var images = NoteAttachmentMedia.items(in: root).filter(\.isImage).map(\.url)
            if NoteAttachmentMedia.imageExtensions.contains(note.pathExtension.lowercased()) { images.insert(note, at: 0) }
            if FileStore.isAudioFile(note) {
                let screen = FileStore.screenshotURL(forRecordingURL: note)
                if FileManager.default.fileExists(atPath: screen.path) { images.append(screen) }
            }
            for image in images where image.isFileURL && FileManager.default.fileExists(atPath: image.path) {
                guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      min(width, height) >= 128 else { continue }
                candidates.append(Target(note: note, image: image.standardizedFileURL.resolvingSymlinksInPath(), date: stamp, dateBasis: basis))
            }
        }
        return select(candidates, limit: limit)
    }

    static func select(_ candidates: [Target], limit: Int) -> [Target] {
        var seen = Set<String>()
        var perNote: [String: Int] = [:]
        return Array(candidates.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.image.path < $1.image.path
        }.filter {
            guard !seen.contains($0.image.path), perNote[$0.note.path, default: 0] < 2 else { return false }
            seen.insert($0.image.path); perNote[$0.note.path, default: 0] += 1
            return true
        }.prefix(max(0, limit)))
    }
}
