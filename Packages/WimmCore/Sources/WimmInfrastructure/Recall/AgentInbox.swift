import Foundation
import WimmDomain

/// Where each agent session stopped reading the inbox (`wimm-cli inbox`).
/// One small file of its own in `AgentState/`: it is not the secretary's
/// pass boundary and not a mark, and nothing here touches `marks.json`, a
/// note or a sidecar. Losing it only makes readers see the last hour again.
public struct AgentInboxCursorStore: Sendable {
    public let directory: URL

    public init(directory: URL = StoragePaths.baseDirectory().appendingPathComponent("AgentState")) {
        self.directory = directory
    }

    struct Reader: Codable {
        var readTo: Date
        var seenAt: Date
    }

    struct Document: Codable {
        var schema = "AgentInbox@v1"
        var readers: [String: Reader] = [:]
    }

    /// Readers not seen for this long are dropped on the next write: a
    /// session id is used for one conversation and never again.
    static let forgetAfter: TimeInterval = 30 * 86_400

    private var url: URL { directory.appendingPathComponent("inbox-cursors.json") }

    public func cursor(for reader: String) -> Date? { read().readers[reader]?.readTo }

    public func advance(_ reader: String, to date: Date, now: Date) throws {
        try AgentStateLock.withLock(in: directory, name: "inbox-cursors") {
            var doc = read()
            doc.readers = doc.readers.filter { now.timeIntervalSince($0.value.seenAt) < Self.forgetAfter }
            doc.readers[reader] = Reader(readTo: date, seenAt: now)
            // Plain coders: dates as numbers, so the cursor keeps its sub-second part.
            try JSONEncoder().encode(doc).write(to: url, options: .atomic)
        }
    }

    private func read() -> Document {
        guard let data = try? Data(contentsOf: url),
              let doc = try? JSONDecoder().decode(Document.self, from: data) else { return Document() }
        return doc
    }
}

/// The short "what changed in the notes since you last looked" digest an
/// agent session gets at the start of a turn (Claude Code `UserPromptSubmit`
/// hook). Read-only over the library; the only write is the reader's cursor,
/// and only after the digest was written out.
public enum AgentInbox {
    public enum Change: String, Sendable { case new, transcript, edited }

    public struct Item: Sendable, Equatable {
        public let id: String
        public let date: Date
        public let kind: String
        public let changes: [Change]
        public let preview: String
    }

    public enum Outcome: Equatable, Sendable {
        /// Nothing new; the cursor moved to `asOf`.
        case nothingNew
        /// Digest written; the cursor moved.
        case reported(Int)
        /// Private mode: nothing read, nothing printed, cursor untouched.
        case privateMode
        /// The digest could not be written; cursor untouched.
        case outputFailed
        case noReader
    }

    /// A reader with no cursor yet sees this far back.
    public static let firstWindow: TimeInterval = 3600
    static let maxItems = 8
    static let previewChars = 120
    static let maxChars = 1800
    /// More changed notes than this are not built at all, only counted.
    static let maxBuilt = 40

    /// `--reader` / `WIMM_INBOX_READER`, else the Claude Code session, else
    /// the `session_id` of the hook's stdin JSON.
    public static func reader(explicit: String?, environment: [String: String], hookInput: Data) -> String? {
        func clean(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(200))
        }
        if let id = clean(explicit) ?? clean(environment["WIMM_INBOX_READER"]) ?? clean(environment["CLAUDE_CODE_SESSION_ID"]) {
            return id
        }
        let json = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any]
        return clean(json?["session_id"] as? String)
    }

    /// Every visible file of the note directories with its mtime: the one
    /// pass over the library a hook call makes.
    public static func libraryListing() -> [String: Date] {
        LibraryRecallSource.modificationDates(
            in: [FileStore.recordingsDirectory(), FileStore.legacyRecordingsDirectory()])
    }

    /// The notes (as `FileRepository` would list them) behind the files of
    /// `listing` modified in `[since, asOf)`, with the later of the note
    /// file's and its sidecar's mtime. Only the touched sessions are grouped,
    /// so an unchanged library costs nothing beyond the listing.
    static func touchedNotes(in listing: [String: Date], since: Date, asOf: Date) -> [(url: URL, at: Date)] {
        var bases = Set<String>()
        for (path, modified) in listing where modified >= since && modified < asOf {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            if let suffix = [".meta.json", ".metadata.json"].first(where: name.hasSuffix) {
                bases.insert(String(name.dropLast(suffix.count)))
            } else {
                bases.insert(FileRepository.canonicalSessionID(for: url))
            }
        }
        guard !bases.isEmpty else { return [] }
        // A session's files all start with its base, cut at a `.` or `_`:
        // a few set lookups per file name, no sort of the whole library.
        var members: [String: [String]] = [:]
        for path in listing.keys {
            let name = path[(path.lastIndex(of: "/").map(path.index(after:)) ?? path.startIndex)...]
            for cut in name.indices where name[cut] == "." || name[cut] == "_" {
                let prefix = String(name[..<cut])
                if bases.contains(prefix) { members[prefix, default: []].append(path) }
            }
        }
        let legacy = FileStore.legacyRecordingsDirectory().path + "/"
        var out: [(url: URL, at: Date)] = []
        for (base, paths) in members {
            var group: [URL] = []
            var seen = Set<String>()
            // By name, as the listing orders a group; the primary directory
            // wins a name present in both.
            for url in paths.map({ URL(fileURLWithPath: $0) }).sorted(by: {
                let (a, b) = ($0.lastPathComponent, $1.lastPathComponent)
                return a != b ? a < b : !$0.path.hasPrefix(legacy) && $1.path.hasPrefix(legacy)
            }) where FileRepository.isListed(url) && FileRepository.canonicalSessionID(for: url) == base {
                if seen.insert(url.lastPathComponent).inserted { group.append(url) }
            }
            guard let anchor = FileRepository.anchor(in: group, base: base) else { continue }
            let sidecar = LibraryRecallSource.sidecarPath(forRecordingPath: anchor.path, listing: listing)
            guard let at = [listing[anchor.path], listing[sidecar]].compactMap({ $0 }).max(),
                  at >= since, at < asOf else { continue }
            out.append((anchor, at))
        }
        return out
    }

    /// Notes that changed in `[since, asOf)` in a way worth a line: new on
    /// this Mac, a transcript run, or an edit by a person. Sync and status
    /// writes are left out. Oldest change first.
    public static func scan(listing: [String: Date], since: Date, asOf: Date) async -> (items: [Item], total: Int) {
        var changed: [(url: URL, at: Date, changes: [Change])] = []
        for (url, at) in touchedNotes(in: listing, since: since, asOf: asOf) {
            var changes: [Change] = []
            if let born = created(url), born >= since { changes.append(.new) }
            let kinds = NoteChangeKind.kinds(forRecordingURL: url, since: since)
            if kinds.contains(.transcript) { changes.append(.transcript) }
            if kinds.contains(.edited), !changes.contains(.new) { changes.append(.edited) }
            if !changes.isEmpty { changed.append((url, at, changes)) }
        }
        changed.sort { $0.at != $1.at ? $0.at < $1.at : $0.url.path < $1.url.path }
        let shown = changed.suffix(maxBuilt)
        let library = await LibraryRecallSource.loadFiles(shown.map(\.url))
        var notes: [String: RecallNote] = [:]
        for index in 0..<library.count { notes[library[index].filePath] = library[index] }
        let items = shown.compactMap { entry -> Item? in
            guard let note = notes[entry.url.path] else { return nil }
            return Item(id: note.id, date: note.date, kind: note.kind, changes: entry.changes, preview: preview(of: note))
        }
        return (items, changed.count - (shown.count - items.count))
    }

    static func created(_ url: URL) -> Date? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let t = info.st_birthtimespec
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_nsec) / 1e9)
    }

    static func preview(of note: RecallNote) -> String {
        let source = note.summary ?? note.text
        if MCPRecallServer.isPlaceholder(source) { return "" }
        let flat = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > previewChars ? String(flat.prefix(previewChars)) + "…" : flat
    }

    /// The digest: newest `maxItems` items, never longer than `maxChars`.
    /// Empty when there is nothing to say.
    public static func render(_ items: [Item], total: Int, since: Date, timeZone: TimeZone = .current) -> String {
        guard !items.isEmpty else { return "" }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyy-MM-dd HH:mm"
        let head = "Wimm inbox: \(total) note(s) new or changed since \(format.string(from: since)). "
            + "One-line previews only; read a note in full with the wimm MCP tool get_note (id in brackets)."
        var lines: [String] = []
        var used = head.count
        for item in items.suffix(maxItems).reversed() {
            var line = "[\(item.id)] \(format.string(from: item.date)) · \(item.kind) · "
                + item.changes.map(\.rawValue).joined(separator: ", ")
            if !item.preview.isEmpty { line += " — " + item.preview }
            // Room is kept for the "more" line below.
            guard used + line.count + 1 <= maxChars - 120 else { break }
            lines.append(line)
            used += line.count + 1
        }
        var out = ([head] + lines).joined(separator: "\n")
        if total > lines.count {
            out += "\n… and \(total - lines.count) more: wimm MCP changed_notes since: \"\(MCPRecallServer.iso(since))\"."
        }
        return out + "\n"
    }

    /// One hook call. `write` must return only after the text is written and
    /// flushed; if it throws, the cursor stays where it was and the same
    /// changes are offered again next time.
    public static func run(
        reader: String?,
        now: Date = Date(),
        isPrivate: Bool = PrivateMode.isEnabled,
        store: AgentInboxCursorStore = AgentInboxCursorStore(),
        listing: () -> [String: Date] = AgentInbox.libraryListing,
        write: (String) throws -> Void
    ) async -> Outcome {
        // As the MCP reading tools: note text does not leave in private mode.
        // The cursor waits too, so nothing is skipped silently.
        if isPrivate { return .privateMode }
        guard let reader else { return .noReader }
        let since = store.cursor(for: reader) ?? now.addingTimeInterval(-firstWindow)
        let (items, total) = await scan(listing: listing(), since: since, asOf: now)
        let text = render(items, total: total, since: since)
        if !text.isEmpty {
            do { try write(text) } catch { return .outputFailed }
        }
        try? store.advance(reader, to: now, now: now)
        return text.isEmpty ? .nothingNew : .reported(total)
    }
}
