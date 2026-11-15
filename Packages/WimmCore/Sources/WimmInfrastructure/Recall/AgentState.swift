import CryptoKit
import Foundation
import WimmDomain

/// What an outside agent (the knowledge-base secretary) keeps in Wimm about
/// notes it has processed: a status mark per note and the boundary of its
/// last pass. Lives in `<base>/AgentState/`, **outside** the sidecars on
/// purpose — a mark must not move a note's modification time or sha256 (it
/// would show up in `changed_notes` as a change of the note), and it is the
/// agent's bookkeeping, not note content: it is neither synced nor shown in
/// the Reader. Losing the folder loses no note.
public struct AgentMarkStore: Sendable {
    public let directory: URL

    public init(directory: URL = StoragePaths.baseDirectory().appendingPathComponent("AgentState")) {
        self.directory = directory
    }

    public struct Mark: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable, CaseIterable {
            /// Built into the knowledge base.
            case applied
            /// Seen, not built in yet.
            case pending
            /// Nothing worth keeping (silence, pocket recording, test).
            case noise
            /// Could not be processed (unreadable, broken transcript).
            case failed
        }

        public var status: Status
        /// The agent's own reference, e.g. a registry id like `S1157`.
        public var source: String?
        public var comment: String?
        public var markedAt: Date
        public var noteId: String
        /// sha256 of the `.meta.json` when the mark was set.
        public var sidecarSHA256: String?
        /// `NoteFingerprint` of the text and of the analysis when the mark was
        /// set: what lets a later listing say "unchanged since your mark" even
        /// though a sync bumped the sidecar.
        public var text: String
        public var analysis: String
        /// `NoteFingerprint.wording` at the mark; nil for marks set before it existed.
        public var wording: String?

        public init(status: Status, source: String?, comment: String? = nil, markedAt: Date, noteId: String,
                    sidecarSHA256: String? = nil, text: String, analysis: String, wording: String? = nil) {
            self.wording = wording
            self.status = status
            self.source = source
            self.comment = comment
            self.markedAt = markedAt
            self.noteId = noteId
            self.sidecarSHA256 = sidecarSHA256
            self.text = text
            self.analysis = analysis
        }
    }

    public struct PassBoundary: Codable, Sendable, Equatable {
        /// `changed_notes` with `since: "last_pass"` starts here.
        public var asOf: Date
        public var cursor: String?
        public var comment: String?
        public var setAt: Date

        public init(asOf: Date, cursor: String?, comment: String?, setAt: Date) {
            self.asOf = asOf
            self.cursor = cursor
            self.comment = comment
            self.setAt = setAt
        }
    }

    struct Document: Codable {
        var schema = "AgentState@v1"
        /// Keyed by the note's file name: the note id is derived from the
        /// full path, the file name is what the agent's registry holds.
        var marks: [String: Mark] = [:]
        var pass: PassBoundary?
    }

    private var url: URL { directory.appendingPathComponent("marks.json") }

    public func marks() -> [String: Mark] { read().marks }

    public func mark(forFile fileName: String) -> Mark? { read().marks[fileName] }

    public func pass() -> PassBoundary? { read().pass }

    /// Sets (or with a nil mark, clears) the marks of these files in one locked write.
    public func update(_ changes: [String: Mark?]) throws {
        try mutate { doc in
            for (file, mark) in changes { doc.marks[file] = mark }
        }
    }

    public func setPass(_ pass: PassBoundary) throws {
        try mutate { $0.pass = pass }
    }

    /// Decoded document, reused while the file is unchanged. `mark(forFile:)`
    /// sits in per-note loops and decoding all marks (MBs of JSON) each time
    /// cost ~20 ms a call. Writes are atomic renames, so another process's
    /// write changes the inode/size/mtime stamp and invalidates this.
    private final class DocumentCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (stamp: Stamp, document: Document)] = [:]
        struct Stamp: Equatable { let inode: UInt64; let size: Int64; let seconds: Int; let nanoseconds: Int }
        func get(_ path: String, _ stamp: Stamp) -> Document? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path], entry.stamp == stamp else { return nil }
            return entry.document
        }
        func set(_ path: String, _ stamp: Stamp, _ document: Document) {
            lock.lock(); defer { lock.unlock() }
            entries[path] = (stamp, document)
        }
    }
    private static let cache = DocumentCache()

    private static func stamp(_ path: String) -> DocumentCache.Stamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return .init(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                     seconds: Int(info.st_mtimespec.tv_sec), nanoseconds: Int(info.st_mtimespec.tv_nsec))
    }

    func read() -> Document {
        let path = url.path
        // Stamp first: a write between stat and read is then re-read next time.
        let before = Self.stamp(path)
        if let before, let cached = Self.cache.get(path, before) { return cached }
        guard let data = try? Data(contentsOf: url) else { return Document() }
        guard let document = try? Self.decoder.decode(Document.self, from: data) else { return Document() }
        if let before { Self.cache.set(path, before, document) }
        return document
    }

    private func mutate(_ change: (inout Document) -> Void) throws {
        try AgentStateLock.withLock(in: directory, name: "marks") {
            var doc = read()
            change(&doc)
            try Self.encoder.encode(doc).write(to: url, options: .atomic)
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // `.iso8601`, with the encoder's own `yyyy-MM-ddTHH:mm:ssZ` parsed directly:
        // a formatter call per mark was most of reading ~8k marks.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = MarkDate.parseUTC(string) ?? MarkDate.formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected date string to be ISO8601-formatted.")
        }
        return decoder
    }()

    enum MarkDate {
        nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = .withInternetDateTime
            return formatter
        }()

        /// Exactly `yyyy-MM-ddTHH:mm:ssZ` with in-range fields; anything else is nil.
        static func parseUTC(_ string: String) -> Date? {
            let b = Array(string.utf8)
            guard b.count == 20, b[4] == 45, b[7] == 45, b[10] == 84, b[13] == 58, b[16] == 58, b[19] == 90 else { return nil }
            func number(_ range: Range<Int>) -> Int? {
                var value = 0
                for i in range { guard (48...57).contains(b[i]) else { return nil }; value = value * 10 + Int(b[i] - 48) }
                return value
            }
            guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
                  let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
                  year >= 1, (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...lengths[month - 1]).contains(day) else { return nil }
            // Days from 1970-01-01 in the proleptic Gregorian calendar.
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let days = era * 146_097 + doe - 719_468
            return Date(timeIntervalSince1970: TimeInterval(days * 86_400 + hour * 3_600 + minute * 60 + second))
        }
    }
}

/// Cross-process lock for the `AgentState` files: the MCP server and the
/// retranscription worker are separate processes writing the same JSON.
public enum AgentStateLock {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(description: String) { self.description = description }
    }

    public static func withLock<T>(in directory: URL, name: String, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appendingPathComponent(".\(name).lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure(description: "cannot open the \(name) lock in \(directory.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw Failure(description: "cannot lock \(name)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Hashes of what a note *says*, read from disk, so an agent can tell a
/// change of content from a sync or status write (which moves the sidecar's
/// mtime and sha256 just the same).
///
/// - `text`: every transcript (current and earlier runs), the local
///   transcript, the typed `.txt`, document/OCR/attachment text, and the
///   refined text once a person edited it.
/// - `analysis`: what the model wrote — title, summary, the unedited refined
///   text — and when (`processed_at`).
public struct NoteFingerprint: Sendable, Equatable, Codable {
    public let text: String
    public let analysis: String
    /// The set of distinct texts with case, punctuation and spacing dropped: a re-run that only
    /// moves a comma keeps it, because the old text stays in previousRuns. nil in old caches.
    public var wording: String? = nil

    public static func read(forRecordingURL mediaURL: URL) -> NoteFingerprint {
        let meta = RecallSidecar.load(forRecordingURL: mediaURL)?.sidecar ?? RecallSidecar([:])
        return make(meta, typed: typedText(at: mediaURL))
    }

    /// Fingerprint of a sidecar dictionary alone (an audio note has no typed file text).
    public static func make(sidecar: [String: Any]) -> NoteFingerprint {
        make(RecallSidecar(sidecar), typed: nil)
    }

    /// The pass queue only compares text and analysis. Check the qualifying
    /// change and compute those hashes from the same parsed sidecar.
    public static func changedForPass(_ mediaURL: URL, since: Date, mark: AgentMarkStore.Mark) -> Bool {
        let meta = RecallSidecar.load(forRecordingURL: mediaURL)?.sidecar ?? RecallSidecar([:])
        let kinds = NoteChangeKind.kinds(meta, since: since,
                                         typedFileChanged: NoteChangeKind.typedFileChanged(mediaURL, since: since))
        guard kinds.contains(.transcript) || kinds.contains(.edited) else { return false }
        let now = make(meta, typed: typedText(at: mediaURL), includeWording: settled(mark))
        return needsPass(mark: mark, now: now)
    }

    /// Whether a marked note's content differs from its mark the way the pass
    /// packet counts it: a settled (noise/applied) note whose re-run only moved
    /// punctuation stays settled. The packet and the pass planner share this,
    /// so the boundary never waits for a note no packet will offer.
    public static func needsPass(mark: AgentMarkStore.Mark, now: NoteFingerprint) -> Bool {
        if settled(mark), sameWording(mark, now) { return false }
        return mark.text != now.text || mark.analysis != now.analysis
    }

    private static func settled(_ mark: AgentMarkStore.Mark) -> Bool {
        mark.status == .noise || mark.status == .applied
    }

    private static func typedText(at mediaURL: URL) -> String? {
        // The file is read only for a text note; its sidecar copy is no typed text.
        NoteContent.load(anchor: mediaURL, sidecar: [:]).fileText
    }

    static func make(_ meta: RecallSidecar, typed: String?, includeWording: Bool = true) -> NoteFingerprint {
        let edited = meta.refinedEditedAt != nil
        var text: [String?] = [meta.transcript, meta.localTranscript, typed, meta.documentText, meta.ocrText]
        text += meta.previousRuns.map(\.transcript)
        text += meta.previousDocumentRuns.map(\.text)
        text += meta.previousOCRRuns.map(\.text)
        text += meta.attachments.map(\.text)
        text += meta.attachments.flatMap { $0.previousRuns.map(\.text) }
        text += meta.imageEvidence.map { Optional($0.text) }
        text.append(edited ? meta.refined : nil)
        let analysis: [String?] = [
            meta.cardTitle, meta.cardSummary, edited ? nil : meta.refined, meta.processedAt,
        ]
        var wording: String?
        if includeWording {
            let words = Set(text.compactMap { $0.map(normalized) }.filter { !$0.isEmpty }).sorted()
            wording = hash(words)
        }
        return NoteFingerprint(text: hash(text), analysis: hash(analysis), wording: wording)
    }

    public static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The mark's text differs only in case, punctuation or spacing.
    public static func sameWording(_ mark: AgentMarkStore.Mark, _ now: NoteFingerprint) -> Bool {
        mark.wording != nil && mark.wording == now.wording
    }

    private static func hash(_ parts: [String?]) -> String {
        // A separator that cannot occur in text keeps ["ab", ""] apart from ["a", "b"].
        let joined = parts.map { $0 ?? "" }.joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(joined.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// What kind of write moved a note's change time at or after a moment, read
/// from the timestamps the pipeline stamps into the sidecar. A hint, not a
/// diff: a transcript synced in from the iPhone carries the phone's run time.
public enum NoteChangeKind: String, Sendable, CaseIterable {
    /// A transcription run finished (or an earlier run was replaced).
    case transcript
    /// The model analysis (title, summary, refined text) was rewritten.
    case analysis
    /// A person edited the text (refined text or a typed `.txt`).
    case edited
    /// CloudKit sync wrote the sidecar.
    case sync
    /// None of the above: a status, flag, trash or attachment write.
    case metadata

    /// The kinds behind a change at or after `since`, in this enum's order.
    public static func kinds(forRecordingURL mediaURL: URL, since: Date) -> [NoteChangeKind] {
        let meta = RecallSidecar.load(forRecordingURL: mediaURL)?.sidecar ?? RecallSidecar([:])
        return kinds(meta, since: since, typedFileChanged: typedFileChanged(mediaURL, since: since))
    }

    fileprivate static func typedFileChanged(_ mediaURL: URL, since: Date) -> Bool {
        guard NoteContent.kind(of: mediaURL) == .text,
              let modified = (try? mediaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return false }
        return modified >= since
    }

    static func kinds(_ meta: RecallSidecar, since: Date, typedFileChanged: Bool = false) -> [NoteChangeKind] {
        func atOrAfter(_ stamp: String?) -> Bool {
            guard let stamp, let date = ISO8601.parseEither(stamp) else { return false }
            return date >= since
        }
        var out: [NoteChangeKind] = []
        if atOrAfter(meta.transcribedAt) || meta.previousRuns.contains(where: { atOrAfter($0.replacedAt) }) || meta.imageEvidenceDates.contains(where:atOrAfter) {
            out.append(.transcript)
        }
        if atOrAfter(meta.processedAt) { out.append(.analysis) }
        if atOrAfter(meta.refinedEditedAt) || typedFileChanged { out.append(.edited) }
        if atOrAfter(meta.syncUpdatedAt) { out.append(.sync) }
        return out.isEmpty ? [.metadata] : out
    }
}

/// Small, rebuildable evidence carried through the build subprocess. Never retains
/// parsed sidecars; a changed or missing input forces a fresh disk read.
public struct NoteFingerprintSnapshot: Sendable, Equatable, Codable {
    struct Stamp: Sendable, Equatable, Codable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
        let changedSeconds: Int64
        let changedNanos: Int64

        init(inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanos: Int64,
             changedSeconds: Int64, changedNanos: Int64) {
            self.inode = inode; self.size = size
            self.modifiedSeconds = modifiedSeconds; self.modifiedNanos = modifiedNanos
            self.changedSeconds = changedSeconds; self.changedNanos = changedNanos
        }

        init?(_ url: URL) { self.init(path: url.path) }

        init(_ info: stat) {
            self.init(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                      modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec),
                      changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanos: Int64(info.st_ctimespec.tv_nsec))
        }

        init?(path: String) {
            var info = stat()
            guard stat(path, &info) == 0 else { return nil }
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = Int64(info.st_mtimespec.tv_sec)
            modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
            changedSeconds = Int64(info.st_ctimespec.tv_sec)
            changedNanos = Int64(info.st_ctimespec.tv_nsec)
        }
    }

    let inputs: [Stamp]
    let fingerprint: NoteFingerprint

    static func stamps(for file: URL) -> [Stamp]? {
        guard let media = Stamp(file),
              let sidecar = Stamp(FileStore.metadataURL(forRecordingURL: file)) else { return nil }
        return [media, sidecar]
    }

    /// `stamps(for:)` when the caller already resolved the sidecar path.
    static func stamps(file: String, sidecar: String) -> [Stamp]? {
        guard let media = Stamp(path: file), let sidecar = Stamp(path: sidecar) else { return nil }
        return [media, sidecar]
    }

    static func capture(file: URL, sidecar: [String: Any], before: [Stamp]?) -> Self? {
        guard let before, !sidecar.isEmpty else { return nil }
        let content = NoteContent.load(anchor: file, sidecar: sidecar)
        // An unreadable typed file cannot attest a version.
        guard !content.fileUnreadable else { return nil }
        let fingerprint = NoteFingerprint.make(RecallSidecar(sidecar), typed: content.fileText)
        guard stamps(for: file) == before else { return nil }
        return Self(inputs: before, fingerprint: fingerprint)
    }

    public func current(for file: URL) -> NoteFingerprint? {
        Self.stamps(for: file) == inputs ? fingerprint : nil
    }
}
