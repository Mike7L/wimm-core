import Foundation
import Darwin
import WimmDomain
import WimmInfrastructure

/// The timeline needs no transcript, attachment text or searchable sidecar JSON.
struct StudioLibraryNote: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileURL: URL
    let metadataURL: URL?
    let absoluteDate: Date
    let studioTitle: String
    let kind: StudioTimeline.Kind
    let minutes: Double

    init(_ note: Note) {
        id = note.id; fileURL = note.fileURL; metadataURL = note.metadataURL
        absoluteDate = note.absoluteDate
        studioTitle = String(note.studioTitle.prefix(200))
        kind = StudioTimeline.Kind.classify(note)
        minutes = StudioTimeline.minutes(of: note, kind: kind)
    }
}

/// One serialized owner, called by RecentNotes' coalescing drain. Unchanged files
/// retain their small projections; only the newest HUD slice retains full Notes.
actor StudioLibraryStore {
    struct Snapshot: Sendable {
        let entries: [StudioLibraryNote]
        let recent: [Note]
        let decoded: Int
        let revision: UInt64
    }
    private struct Stamp: Equatable, Sendable {
        let seconds: Int, nanos: Int, size: Int64, inode: UInt64
        init(_ info: stat) {
            seconds = info.st_mtimespec.tv_sec; nanos = info.st_mtimespec.tv_nsec
            size = info.st_size; inode = UInt64(info.st_ino)
        }
        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            self.init(info)
        }
    }
    /// Compact paths/stamps acquired once, without thousands of Foundation URL resource caches.
    private struct DirectorySnapshot {
        var stamps: [String: Stamp] = [:]
        var names: [URL: [String]] = [:]
        init(_ directories: Set<URL>) {
            for directory in directories {
                guard let stream = opendir(directory.path) else { continue }
                defer { closedir(stream) }
                let fd = dirfd(stream), prefix = directory.path + "/"
                var listing: [String] = []
                while let entry = readdir(stream) {
                    let name = withUnsafePointer(to: entry.pointee.d_name) {
                        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
                    }
                    guard !name.hasPrefix(".") else { continue }
                    listing.append(name)
                    var info = stat()
                    if fstatat(fd, name, &info, 0) == 0 { stamps[prefix + name] = Stamp(info) }
                }
                names[directory] = listing
            }
        }
        func metadata(_ file: URL) -> URL {
            var base = file.deletingPathExtension().lastPathComponent
            if let range = base.range(of: "_Attach_") { base = String(base[..<range.lowerBound]) }
            let primary = file.deletingLastPathComponent().appendingPathComponent(base + ".meta.json")
            let legacy = file.deletingLastPathComponent().appendingPathComponent(base + ".metadata.json")
            return stamps[primary.path] != nil || stamps[legacy.path] == nil ? primary : legacy
        }
    }
    private struct Version: Equatable, Sendable {
        let primary: Stamp?, sidecar: Stamp?, legacy: Stamp?
        init(_ url: URL, snapshot: DirectorySnapshot? = nil) {
            if let snapshot {
                primary = snapshot.stamps[url.path]
                sidecar = snapshot.stamps[snapshot.metadata(url).path]
                legacy = snapshot.stamps[snapshot.metadata(FileStore.miniURL(forRecordingURL: url)).path]
            } else {
                primary = Stamp(url)
                sidecar = Stamp(FileStore.metadataURL(forRecordingURL: url))
                legacy = Stamp(FileStore.metadataURL(forRecordingURL: FileStore.miniURL(forRecordingURL: url)))
            }
        }
    }
    private struct Item: Sendable {
        let version: Version
        let entry: StudioLibraryNote?
    }
    private let repository: any FileRepositoryProtocol
    private let metadata: any MetadataRepositoryProtocol
    private let transcripts: any TranscriptRepositoryProtocol
    private var items: [URL: Item] = [:]
    private var hud: [URL: Note] = [:]
    private var revision: UInt64 = 0
    private let limit: Int

    init(limit: Int, repository: any FileRepositoryProtocol = FileRepository(),
         metadata: any MetadataRepositoryProtocol = MetadataRepository(),
         transcripts: any TranscriptRepositoryProtocol = TranscriptRepository()) {
        self.limit = max(0, limit); self.repository = repository
        self.metadata = metadata; self.transcripts = transcripts
    }

    /// nil reconciles discovery and versions (including outside edits/deletes).
    /// Known local changes skip library discovery and decoding of unchanged notes.
    func update(changedFiles: Set<URL>? = nil, preview: (@Sendable (Snapshot) async -> Void)? = nil) async -> Snapshot {
        let firstLoad = items.isEmpty
        let previousCount = items.count
        var candidates: [URL]
        let snapshot: DirectorySnapshot?
        let index: RecordingsDirectoryIndex
        if let changedFiles {
            candidates = Array(changedFiles)
            snapshot = nil
            let directories = Array(Set(candidates.map { $0.deletingLastPathComponent() }))
            index = RecordingsDirectoryIndex(directories: directories)
        } else {
            await repository.invalidateCache()
            candidates = await repository.recordings(order: .descending, limit: nil)
            let directories = Set(candidates.map { $0.deletingLastPathComponent() })
            let snap = DirectorySnapshot(directories)
            snapshot = snap
            index = RecordingsDirectoryIndex(directoryFilenames: snap.names)
            let existing = Set(candidates)
            items = items.filter { existing.contains($0.key) }
            hud = hud.filter { existing.contains($0.key) }
        }
        let versions = Dictionary(uniqueKeysWithValues: candidates.map { ($0, Version($0, snapshot: snapshot)) })
        let changed = candidates.filter { items[$0]?.version != versions[$0] }
        var decoded = 0
        let metaRepo = metadata
        let transcriptRepo = transcripts
        let dirIndex = index
        func isOlder(_ lhs: StudioLibraryNote, _ rhs: StudioLibraryNote) -> Bool {
            lhs.absoluteDate == rhs.absoluteDate ? lhs.fileURL.path < rhs.fileURL.path : lhs.absoluteDate < rhs.absoluteDate
        }
        var newestChanged: [StudioLibraryNote] = []
        await withTaskGroup(of: (URL, Note).self) { group in
            var iterator = changed.makeIterator()
            func enqueue() {
                guard let file = iterator.next() else { return }
                group.addTask {
                    let note = await NoteBuilder.build(file: file, index: 0, metaRepo: metaRepo,
                                                       transcriptRepo: transcriptRepo, directoryIndex: dirIndex,
                                                       includeSearchMetadata: false)
                    return (file, note)
                }
            }
            for _ in 0..<min(16, changed.count) { enqueue() }
            while let (file, note) = await group.next() {
                decoded += 1
                let entry = note.isCanceled ? nil : StudioLibraryNote(note)
                if let ver = versions[file] {
                    items[file] = Item(version: ver, entry: entry)
                }
                hud.removeValue(forKey: file)
                // Keep the newest changed notes by the same order as the final HUD.
                if let entry, limit > 0,
                   newestChanged.count < limit || isOlder(newestChanged[0], entry) {
                    let index = newestChanged.firstIndex { isOlder(entry, $0) } ?? newestChanged.endIndex
                    newestChanged.insert(entry, at: index)
                    hud[file] = note
                    if newestChanged.count > limit {
                        hud.removeValue(forKey: newestChanged.removeFirst().fileURL)
                    }
                }
                if firstLoad, decoded == limit, let preview {
                    let entries = items.values.compactMap(\.entry).sorted { $0.absoluteDate < $1.absoluteDate }
                    await preview(Snapshot(entries: entries, recent: entries.compactMap { hud[$0.fileURL] }, decoded: decoded, revision: revision))
                }
                enqueue()
            }
        }
        for file in candidates where !FileManager.default.fileExists(atPath: file.path) {
            items.removeValue(forKey: file)
            hud.removeValue(forKey: file)
        }
        let ordered = items.values.compactMap(\.entry).sorted(by: isOlder)
        let wanted = Set(ordered.suffix(limit).map(\.fileURL))
        hud = hud.filter { wanted.contains($0.key) }
        // A deletion/cancellation can promote a previously non-HUD entry.
        for file in wanted where hud[file] == nil {
            let note = await NoteBuilder.build(file: file, index: 0, metaRepo: metadata,
                                              transcriptRepo: transcripts, directoryIndex: dirIndex,
                                              includeSearchMetadata: false)
            decoded += 1
            if !note.isCanceled { hud[file] = note }
        }
        if decoded > 0 || items.count != previousCount { revision &+= 1 }
        return Snapshot(entries: ordered, recent: ordered.suffix(limit).compactMap { hud[$0.fileURL] },
                        decoded: decoded, revision: revision)
    }
}
