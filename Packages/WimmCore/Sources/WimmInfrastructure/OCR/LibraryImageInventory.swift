import Foundation
import WimmDomain

/// Full-library inventory. Unlike the benchmark sampler, there is no per-note,
/// date, count, or minimum-size filter. Only active original image assets are used.
public enum LibraryImageInventory {
    public struct Target: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable { case standalone, screenshot, attachment, orphan }
        public let note: String?
        public let image: String
        public let kind: Kind
        public let attachmentID: UUID?
        public init(note: String?, image: String, kind: Kind, attachmentID: UUID? = nil) {
            self.note = note; self.image = image; self.kind = kind; self.attachmentID = attachmentID
        }
    }

    /// Resolve one note without loading the entire library or generated PDF previews.
    public static func targets(for note: URL) -> [Target] {
        guard FileManager.default.fileExists(atPath:note.path) else { return [] }
        let root = (try? Data(contentsOf: FileStore.metadataURL(forRecordingURL: note))).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String:Any]
        } ?? [:]
        var result: [Target] = [], seen = Set<String>()
        func add(_ url: URL, _ kind: Target.Kind, _ id: UUID? = nil) {
            let source = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard isImage(url), FileManager.default.fileExists(atPath: source), seen.insert(source).inserted else { return }
            result.append(Target(note:note.path,image:source,kind:kind,attachmentID:id))
        }
        if isImage(note) { add(note, FileStore.isAttachmentFile(note) ? .attachment : .standalone, FileStore.isAttachmentFile(note) ? note.stableUUID : nil) }
        for item in NoteAttachmentMedia.items(in: root) { add(item.url,.attachment,item.id) }
        // The directory holds the whole library (~17k files) and this runs once
        // per note: a session base is always a name prefix, so reject by name
        // before building URLs or sorting.
        let directory = note.deletingLastPathComponent(), base = sessionBase(note)
        let names = DirectoryNames.list(directory)
        let siblings = names.filter { $0.hasPrefix(base) }.map { directory.appendingPathComponent($0) }
        for image in siblings.sorted(by: { $0.path < $1.path }) where sessionBase(image) == base {
            if FileStore.isAttachmentFile(image) { add(image,.attachment,image.stableUUID) }
            else if FileStore.isAudioFile(note) { add(image,.screenshot) }
        }
        return result
    }
    /// File names of a directory, reused while the directory itself is
    /// unchanged: adding, removing or renaming an entry changes its mtime.
    /// Listing the library folder (~17k files) per note cost ~45 ms a call.
    private final class DirectoryNames: @unchecked Sendable {
        private struct Stamp: Equatable { let inode: UInt64; let seconds: Int; let nanoseconds: Int }
        private let lock = NSLock()
        private var cache: [String: (stamp: Stamp, names: [String])] = [:]
        static let shared = DirectoryNames()

        static func list(_ directory: URL) -> [String] { shared.names(in: directory) }

        private func names(in directory: URL) -> [String] {
            let path = directory.path
            var info = stat()
            guard stat(path, &info) == 0 else { return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] }
            let stamp = Stamp(inode: UInt64(info.st_ino), seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
            lock.lock(); defer { lock.unlock() }
            if let hit = cache[path], hit.stamp == stamp { return hit.names }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            cache[path] = (stamp, names)
            return names
        }
    }

    public struct Inventory: Codable, Sendable {
        public let targets: [Target]
        public let notes: Int
        public let excludedPreviews: Int
        public let missingAttachments: Int
        public var missingTargets: [Target]? = nil
    }

    public static func scan() async -> Inventory {
        let notes = await FileRepository().recordings(order: .descending)
        let directories = Set(notes.map { $0.deletingLastPathComponent() } + [FileStore.recordingsDirectory(), FileStore.legacyRecordingsDirectory()])
        var groups: [String: [String: [URL]]] = [:]
        var physical = Set<URL>()
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for image in files where isImage(image) {
                let url = image.standardizedFileURL.resolvingSymlinksInPath()
                groups[directory.standardizedFileURL.path, default: [:]][sessionBase(image), default: []].append(url)
                physical.insert(url)
            }
        }
        var targets = Set<Target>(), referenced = Set<URL>(), excluded = Set<URL>()
        var previews = 0, missing = 0, activeNotes = 0
        var missingTargets: [Target] = []
        for note in notes {
            let root = (try? Data(contentsOf: FileStore.metadataURL(forRecordingURL: note))).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            let related = groups[note.deletingLastPathComponent().standardizedFileURL.path]?[sessionBase(note)] ?? []
            let indexed = NoteAttachmentMedia.items(in: root).filter { isImage($0.url) }
            activeNotes += 1
            var local = Set<URL>()
            func add(_ image: URL, kind: Target.Kind, id: UUID? = nil) {
                let image = image.standardizedFileURL.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: image.path) else {
                    missing += 1; missingTargets.append(Target(note:note.path,image:image.path,kind:kind,attachmentID:id)); return
                }
                guard local.insert(image).inserted else { return }
                referenced.insert(image)
                targets.insert(Target(note: note.path, image: image.path, kind: kind, attachmentID: id))
            }
            if isImage(note) && !FileStore.isAttachmentFile(note) { add(note, kind: .standalone) }
            for item in indexed { add(item.url, kind: .attachment, id: item.id) }
            if isImage(note) && FileStore.isAttachmentFile(note) { add(note, kind: .attachment, id: note.stableUUID) }
            for image in related {
                if local.contains(image) { continue }
                if image.lastPathComponent.contains("_Attach_") {
                    add(image, kind: .attachment, id: image.stableUUID)
                } else if FileStore.isAudioFile(note) {
                    add(image, kind: .screenshot)
                } else if image != note {
                    // The image next to a PDF/office note is its generated page preview.
                    if FileStore.isDerivedPreviewImage(image, sessionBase: sessionBase(note)) {
                        if excluded.insert(image).inserted { previews += 1 }
                    }
                }
            }
        }
        for image in physical.subtracting(referenced).subtracting(excluded) {
            // Keep an otherwise unowned image in the report, but never invent a note
            // or a parent sidecar for it when results are applied.
            targets.insert(Target(note: nil, image: image.path, kind: .orphan, attachmentID: nil))
        }
        return Inventory(targets: targets.sorted { ($0.note ?? "", $0.image) > ($1.note ?? "", $1.image) },
                         notes: activeNotes, excludedPreviews: previews, missingAttachments: missing, missingTargets: missingTargets)
    }

    static func isImage(_ url: URL) -> Bool {
        NoteAttachmentMedia.imageExtensions.union(["tif"]).contains(url.pathExtension.lowercased())
    }
    static func sessionBase(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        if let range = stem.range(of: "_Attach_") { return String(stem[..<range.lowerBound]) }
        if let range = stem.range(of: "_screen", options: .backwards), !stem[range.upperBound...].isEmpty,
           stem[range.upperBound...].allSatisfy(\.isNumber) { return String(stem[..<range.lowerBound]) }
        return FileStore.strippingDerivedAudioSuffix(stem)
    }
}
