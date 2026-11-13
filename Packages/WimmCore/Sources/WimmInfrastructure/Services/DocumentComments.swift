import Foundation

/// Comments and reactions on a selection of a Markdown document, kept next to
/// the document instead of inside it (`docs/Document_Comments.md`).
///
/// The file is append-only JSON Lines shared by the owner (the Personal
/// document window) and the secretary (`wimm-cli comments`, or any agent that
/// appends the same records). A thread is folded from its records: the root
/// comment or reaction, replies, and status changes. Nothing is ever rewritten.
public struct DocumentCommentRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case comment, reaction, reply, status }

    public var id: String
    public var kind: Kind
    /// Document path relative to the workspace root (or its file name).
    public var doc: String
    public var author: String
    public var at: String
    public var text: String?
    /// Root records: where the selection was.
    public var section: String?
    public var heading: String?
    public var quote: String?
    public var prefix: String?
    public var suffix: String?
    /// Reactions: the emoji and what it asks the secretary to do.
    public var reaction: String?
    public var intent: String?
    /// Replies and status changes: the thread they belong to.
    public var replyTo: String?
    public var status: String?
    /// Where the text came from when it was not typed, e.g.
    /// `voice:Recordings/Wimm_….m4a.meta.json#t=12.0-19.5` for a comment
    /// spoken while the selection was active. Optional; older lines lack it.
    public var via: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, doc, author, at, text, section, heading, quote, prefix, suffix, reaction, intent, status, via
        case replyTo = "reply_to"
    }

    public init(id: String, kind: Kind, doc: String, author: String, at: String, text: String? = nil,
                section: String? = nil, heading: String? = nil, quote: String? = nil,
                prefix: String? = nil, suffix: String? = nil, reaction: String? = nil,
                intent: String? = nil, replyTo: String? = nil, status: String? = nil, via: String? = nil) {
        self.id = id; self.kind = kind; self.doc = doc; self.author = author; self.at = at
        self.text = text; self.section = section; self.heading = heading; self.quote = quote
        self.prefix = prefix; self.suffix = suffix; self.reaction = reaction; self.intent = intent
        self.replyTo = replyTo; self.status = status; self.via = via
    }
}

public enum DocumentCommentAuthor {
    public static let owner = "owner"
    public static let secretary = "secretary"
}

/// `open → answered → applied → resolved`, or `dropped` (withdrawn / "не помню").
public enum DocumentCommentStatus: String, CaseIterable, Sendable {
    case open, answered, applied, resolved, dropped
    public var isClosed: Bool { self == .resolved || self == .dropped }
}

/// The ready-made reactions. Each one names what it asks of the secretary, so
/// an agent never has to guess what an emoji meant.
public enum DocumentReaction: String, CaseIterable, Sendable {
    case agree, wrong, unclear, expand, trim, important

    public var emoji: String {
        switch self {
        case .agree: "👍"
        case .wrong: "❌"
        case .unclear: "❓"
        case .expand: "💡"
        case .trim: "✂️"
        case .important: "⭐"
        }
    }

    /// The instruction the secretary reads (English, stable; UI labels are localized).
    public var instruction: String {
        switch self {
        case .agree: "Owner confirms this text is correct; keep it as is."
        case .wrong: "Owner says this is wrong; ask what is right or fix it from the sources."
        case .unclear: "Owner does not understand this; rewrite it more plainly or explain."
        case .expand: "Owner wants more here; elaborate from the sources or ask."
        case .trim: "Owner finds this unneeded; shorten or remove it."
        case .important: "Owner marks this as important; keep it prominent."
        }
    }

    public init?(emoji: String) {
        guard let match = Self.allCases.first(where: { $0.emoji == emoji }) else { return nil }
        self = match
    }
}

/// A root comment or reaction with its replies and current status.
public struct DocumentCommentThread: Identifiable, Sendable, Equatable {
    public let root: DocumentCommentRecord
    public var replies: [DocumentCommentRecord]
    public var status: DocumentCommentStatus
    public var id: String { root.id }
    public var isReaction: Bool { root.kind == .reaction }

    public init(root: DocumentCommentRecord, replies: [DocumentCommentRecord], status: DocumentCommentStatus) {
        self.root = root; self.replies = replies; self.status = status
    }
    public var selector: TextQuoteSelector {
        TextQuoteSelector(quote: root.quote ?? "", prefix: root.prefix ?? "", suffix: root.suffix ?? "")
    }

    /// Folds records in file order. A status record sets the status; an owner
    /// reply after a secretary answer reopens the thread. Orphans are ignored.
    public static func fold(_ records: [DocumentCommentRecord], doc: String? = nil) -> [DocumentCommentThread] {
        var order: [String] = []
        var threads: [String: DocumentCommentThread] = [:]
        for record in records where doc == nil || record.doc == doc {
            switch record.kind {
            case .comment, .reaction:
                guard threads[record.id] == nil else { continue }
                order.append(record.id)
                threads[record.id] = DocumentCommentThread(
                    root: record, replies: [],
                    status: record.status.flatMap(DocumentCommentStatus.init(rawValue:)) ?? .open)
            case .reply:
                guard let target = record.replyTo, var thread = threads[target] else { continue }
                thread.replies.append(record)
                if let status = record.status.flatMap(DocumentCommentStatus.init(rawValue:)) {
                    thread.status = status
                } else if record.author == DocumentCommentAuthor.owner, thread.status == .answered {
                    thread.status = .open
                }
                threads[target] = thread
            case .status:
                guard let target = record.replyTo, var thread = threads[target],
                      let status = record.status.flatMap(DocumentCommentStatus.init(rawValue:)) else { continue }
                thread.status = status
                threads[target] = thread
            }
        }
        return order.compactMap { threads[$0] }
    }
}

/// W3C-style text quote anchor: the selected text plus a little context on
/// each side, so it survives edits elsewhere and picks the right occurrence.
public struct TextQuoteSelector: Sendable, Equatable {
    public static let contextLength = 32
    public let quote: String
    public let prefix: String
    public let suffix: String

    public init(quote: String, prefix: String, suffix: String) {
        self.quote = quote; self.prefix = prefix; self.suffix = suffix
    }

    public init(selecting range: NSRange, in text: String) {
        let ns = text as NSString
        let start = max(0, range.location - Self.contextLength)
        let end = min(ns.length, NSMaxRange(range) + Self.contextLength)
        quote = ns.substring(with: range)
        prefix = ns.substring(with: NSRange(location: start, length: range.location - start))
        suffix = ns.substring(with: NSRange(location: NSMaxRange(range), length: end - NSMaxRange(range)))
    }

    /// The quote's range in `text`: exact match first, then one that ignores
    /// whitespace and Markdown markup (so a quote taken from rendered text is
    /// found in the source). Several matches are ranked by their context.
    public func resolve(in text: String) -> NSRange? {
        resolve(in: text) { Skeleton(text) }
    }

    /// `skeleton` builds (or returns a cached) `Skeleton(text)`, only when needed.
    func resolve(in text: String, skeleton: () -> Skeleton) -> NSRange? {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let exact = Self.best(of: Self.occurrences(of: quote, in: text), in: text, prefix: prefix, suffix: suffix) {
            return exact
        }
        let source = skeleton()
        let needle = Skeleton(quote).text
        guard !needle.isEmpty else { return nil }
        let candidates = Self.occurrences(of: needle, in: source.text)
        let skeletonPrefix = Skeleton(prefix).text, skeletonSuffix = Skeleton(suffix).text
        guard let match = Self.best(of: candidates, in: source.text, prefix: skeletonPrefix, suffix: skeletonSuffix) else { return nil }
        return source.originalRange(match)
    }

    private static func occurrences(of needle: String, in text: String) -> [NSRange] {
        let ns = text as NSString
        var result: [NSRange] = []
        var searchFrom = 0
        while searchFrom < ns.length {
            let found = ns.range(of: needle, range: NSRange(location: searchFrom, length: ns.length - searchFrom))
            guard found.location != NSNotFound else { break }
            result.append(found)
            searchFrom = found.location + max(found.length, 1)
        }
        return result
    }

    private static func best(of candidates: [NSRange], in text: String, prefix: String, suffix: String) -> NSRange? {
        guard candidates.count > 1 else { return candidates.first }
        let ns = text as NSString
        func score(_ range: NSRange) -> Int {
            let before = ns.substring(to: range.location)
            let after = ns.substring(from: NSMaxRange(range))
            return commonSuffix(before, prefix) + commonPrefix(after, suffix)
        }
        return candidates.max { score($0) < score($1) }
    }

    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix(while: { $0 == $1 }).count
    }

    private static func commonSuffix(_ a: String, _ b: String) -> Int {
        zip(a.reversed(), b.reversed()).prefix(while: { $0 == $1 }).count
    }

    /// Text without whitespace and inline Markdown markup, with a map back to
    /// UTF-16 offsets of the original.
    struct Skeleton {
        let text: String
        private let offsets: [Int]
        private let lengths: [Int]

        init(_ original: String) {
            // Link targets, reference markers and list markers do not render.
            var hidden = IndexSet()
            let ns = original as NSString
            let patterns = [#"\]\([^)\s]*\)"#, #"(?m)^\s*(?:[-+*]|\d+[.)])\s+"#, #"(?m)^\s*>\s?"#, #"(?m)^#{1,6}\s+"#]
            for pattern in patterns {
                let regex = try! NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: original, range: NSRange(location: 0, length: ns.length)) {
                    // Keep the "]" of a link; it is dropped as markup below.
                    let range = pattern.hasPrefix(#"\]"#) ? NSRange(location: match.range.location + 1, length: match.range.length - 1) : match.range
                    hidden.insert(integersIn: range.location..<NSMaxRange(range))
                }
            }
            let markup: Set<Character> = ["*", "_", "`", "~", "[", "]", "•", "#", ">"]
            var text = ""
            var offsets: [Int] = [], lengths: [Int] = []
            var offset = 0
            for character in original {
                let length = String(character).utf16.count
                defer { offset += length }
                if hidden.contains(offset) || character.isWhitespace || markup.contains(character) { continue }
                let lowered = String(character).lowercased()
                text += lowered
                for _ in 0..<lowered.utf16.count { offsets.append(offset); lengths.append(length) }
            }
            self.text = text
            self.offsets = offsets
            self.lengths = lengths
        }

        func originalRange(_ range: NSRange) -> NSRange? {
            guard range.length > 0, NSMaxRange(range) <= offsets.count else { return nil }
            let start = offsets[range.location]
            let last = NSMaxRange(range) - 1
            return NSRange(location: start, length: offsets[last] + lengths[last] - start)
        }
    }
}

/// Where a document's comments live: `<root>/secretary/threads.jsonl` when the
/// document sits in a workspace with a `secretary/` folder (the `_ME` layout),
/// otherwise `<name>.threads.jsonl` beside the document.
public struct DocumentCommentLocation: Sendable, Equatable {
    public let fileURL: URL
    /// The `doc` value of this document's records.
    public let doc: String

    public init(fileURL: URL, doc: String) { self.fileURL = fileURL; self.doc = doc }

    public init(document: URL) {
        let document = document.standardizedFileURL
        var directory = document.deletingLastPathComponent()
        for _ in 0..<4 {
            var isDirectory: ObjCBool = false
            let secretary = directory.appendingPathComponent("secretary")
            if FileManager.default.fileExists(atPath: secretary.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let rootPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
                self.init(fileURL: secretary.appendingPathComponent("threads.jsonl"),
                          doc: String(document.path.dropFirst(rootPath.count)))
                return
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        self.init(fileURL: document.deletingPathExtension().appendingPathExtension("threads.jsonl"),
                  doc: document.lastPathComponent)
    }
}

public actor DocumentCommentStore {
    public nonisolated let location: DocumentCommentLocation
    public init(location: DocumentCommentLocation) { self.location = location }
    public init(document: URL) { location = DocumentCommentLocation(document: document) }

    public struct Snapshot: Sendable {
        public let threads: [DocumentCommentThread]
        /// Lines that are not valid records; kept in the file, skipped here.
        public let skippedLines: Int
        public let modified: Date?
    }

    public func load() throws -> Snapshot {
        let url = location.fileURL
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Snapshot(threads: [], skippedLines: 0, modified: nil)
        }
        var data = Data()
        var coordinationError: NSError?
        var failure: Error?
        var coordinated = false
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            coordinated = true
            do { data = try Data(contentsOf: target) } catch { failure = error }
        }
        // A sandboxed agent process (Codex's workspace-write) cannot reach the
        // file-coordination daemon; the file itself is still readable.
        if !coordinated, coordinationError != nil { data = try Data(contentsOf: url) }
        else {
            if let coordinationError { throw coordinationError }
            if let failure { throw failure }
        }
        let decoder = JSONDecoder()
        var records: [DocumentCommentRecord] = []
        var skipped = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.allSatisfy({ $0 == 32 || $0 == 13 }) {
            if let record = try? decoder.decode(DocumentCommentRecord.self, from: Data(line)) { records.append(record) }
            else { skipped += 1 }
        }
        return Snapshot(threads: DocumentCommentThread.fold(records, doc: location.doc), skippedLines: skipped, modified: modified)
    }

    /// Appends one record as one line. Coordinated with other writers in this
    /// process and with `NSFilePresenter`s; an outside agent appends whole
    /// lines the same way.
    public func append(_ record: DocumentCommentRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(UInt8(ascii: "\n"))
        let url = location.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        func appendLine(to target: URL) throws {
            if !FileManager.default.fileExists(atPath: target.path) {
                FileManager.default.createFile(atPath: target.path, contents: nil)
            }
            let handle = try FileHandle(forUpdating: target)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            // A previous writer may have left a line without its newline.
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data([UInt8(ascii: "\n")]) { line.insert(UInt8(ascii: "\n"), at: 0) }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: line)
        }
        var coordinationError: NSError?
        var failure: Error?
        var coordinated = false
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
            coordinated = true
            do { try appendLine(to: target) } catch { failure = error }
        }
        // Without the coordination daemon (a sandboxed agent) append the whole
        // line directly: one short write, as an outside agent would.
        if !coordinated, coordinationError != nil { try appendLine(to: url) }
        else {
            if let coordinationError { throw coordinationError }
            if let failure { throw failure }
        }
    }

    // MARK: - Record builders

    public nonisolated func newRoot(kind: DocumentCommentRecord.Kind, selector: TextQuoteSelector, section: String?,
                        heading: String?, text: String?, reaction: DocumentReaction? = nil,
                        author: String = DocumentCommentAuthor.owner, now: Date = Date()) -> DocumentCommentRecord {
        DocumentCommentRecord(
            id: Self.makeID(prefix: "c", now: now), kind: kind, doc: location.doc, author: author,
            at: Self.timestamp(now), text: text, section: section, heading: heading,
            quote: selector.quote, prefix: selector.prefix, suffix: selector.suffix,
            reaction: reaction?.emoji, intent: reaction?.rawValue)
    }

    public nonisolated func newReply(to threadID: String, text: String, author: String,
                         status: DocumentCommentStatus? = nil, now: Date = Date()) -> DocumentCommentRecord {
        DocumentCommentRecord(id: Self.makeID(prefix: "r", now: now), kind: .reply, doc: location.doc,
                              author: author, at: Self.timestamp(now), text: text,
                              replyTo: threadID, status: status?.rawValue)
    }

    public nonisolated func newStatus(of threadID: String, _ status: DocumentCommentStatus, author: String,
                          now: Date = Date()) -> DocumentCommentRecord {
        DocumentCommentRecord(id: Self.makeID(prefix: "s", now: now), kind: .status, doc: location.doc,
                              author: author, at: Self.timestamp(now), replyTo: threadID, status: status.rawValue)
    }

    static func makeID(prefix: String, now: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        let random = (0..<6).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        return "\(prefix)-\(day.string(from: now))-\(random)"
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

extension PersonalDocument {
    /// The section a block belongs to: the nearest heading at or above it,
    /// as its stable anchor id when it has one, else its title.
    public func section(of block: Block) -> (id: String, heading: String)? {
        guard let heading = blocks.prefix(through: block.id).last(where: {
            if case .heading = $0.kind { return true }; return false
        }) else { return nil }
        let title = heading.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        return (heading.anchor ?? title, title)
    }

    /// The block a thread's quote lands in, preferring its recorded section.
    /// Edited quotes can still land beside a confidently matching paragraph.
    /// nil means no unambiguous placement survived.
    public func block(for thread: DocumentCommentThread) -> Block? {
        place([thread])[thread.id].flatMap { id in blocks.first { $0.id == id } }
    }

    /// Thread id → block id for every thread that still lands somewhere.
    /// Each block's reading text and skeleton are built once for all threads.
    public func place(_ threads: [DocumentCommentThread]) -> [String: Int] {
        let candidates = blocks.filter { if case .hidden = $0.kind { return false }; return true }
        let texts = candidates.map { displayMarkdown(for: $0) }
        let sections = candidates.map { section(of: $0)?.id }
        let headings = candidates.map { section(of: $0)?.heading }
        // Paragraph recovery is separate from exact range resolution: a changed
        // quote must not produce a misleading highlight in the new text.
        let evidence = texts.map(CommentParagraphEvidence.init)
        var skeletons: [Int: TextQuoteSelector.Skeleton] = [:]
        func skeleton(_ index: Int) -> TextQuoteSelector.Skeleton {
            if let cached = skeletons[index] { return cached }
            let built = TextQuoteSelector.Skeleton(texts[index]); skeletons[index] = built; return built
        }
        var result: [String: Int] = [:]
        for thread in threads {
            let selector = thread.selector
            let inSection = candidates.indices.filter { sections[$0] == thread.root.section }
            for group in [inSection, Array(candidates.indices)] {
                if let index = group.first(where: { index in selector.resolve(in: texts[index], skeleton: { skeleton(index) }) != nil }) {
                    result[thread.id] = candidates[index].id
                    break
                }
            }
            guard result[thread.id] == nil else { continue }
            // A correction may already have replaced the entire old sentence.
            // Owner wording is another anchor; secretary replies are commentary,
            // not selections or owner corrections, so do not use them as anchors.
            let anchorTexts = [[selector.prefix, selector.quote, selector.suffix].joined(separator: " ")]
                + [thread.root.text].compactMap { $0 }
                + thread.replies.filter { $0.author == DocumentCommentAuthor.owner }.compactMap(\.text)
            let anchors = anchorTexts.map(CommentParagraphEvidence.init)
            let matches = candidates.indices.compactMap { index -> (index: Int, score: Double)? in
                guard case .body = candidates[index].kind,
                      let score = anchors.compactMap({ $0.similarity(to: evidence[index]) }).max() else { return nil }
                let sameSection = thread.root.section != nil && sections[index] == thread.root.section
                let sameHeading = thread.root.heading != nil && headings[index] == thread.root.heading
                return (index, score + (sameSection || sameHeading ? 0.15 : 0))
            }
            // A large overview often repeats the same correction as its actual
            // paragraph. Prefer the specific paragraph; similar-sized competing
            // paragraphs still remain ambiguous.
            let shortest = matches.map { evidence[$0.index].words.count }.min() ?? 0
            let ranked = matches.map { match in
                (index: match.index, score: match.score - (evidence[match.index].words.count >= max(1, shortest) * 3 ? 0.2 : 0))
            }.sorted { $0.score > $1.score }
            if let best = ranked.first,
               ranked.count == 1 || best.score - ranked[1].score >= 0.12 {
                result[thread.id] = candidates[best.index].id
            }
        }
        return result
    }
}

/// Conservative lexical recovery for edited paragraphs, including old threads.
/// Requires several distinct surviving words and some preserved word order;
/// neither a section alone nor a generic short selection is enough evidence.
private struct CommentParagraphEvidence {
    let words: Set<String>
    let pairs: Set<String>

    init(_ text: String) {
        let reading = text
            .replacingOccurrences(of: #"\]\([^)]*\)"#, with: "]", options: .regularExpression)
            .replacingOccurrences(of: #"\[S\d+\]"#, with: "", options: .regularExpression)
        let tokens = reading.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        words = Set(tokens.filter { $0.count >= 3 })
        pairs = Set(zip(tokens, tokens.dropFirst()).compactMap { a, b in
            a.count >= 3 && b.count >= 3 ? a + " " + b : nil
        })
    }

    func similarity(to other: Self) -> Double? {
        guard words.count >= 4 else { return nil }
        let shared = words.intersection(other.words).count
        let sharedPairs = pairs.intersection(other.pairs).count
        let coverage = Double(shared) / Double(words.count)
        guard shared >= 4, sharedPairs >= 1, coverage >= 0.5 else { return nil }
        let score = 0.75 * coverage + 0.25 * Double(sharedPairs) / Double(max(1, pairs.count))
        return score >= 0.5 ? score : nil
    }
}
