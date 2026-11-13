import Foundation
import WimmDomain

/// Reader's literal, case-insensitive substring search. Unlike NoteRecall this
/// does not tokenize, rank, or omit metadata. Like RecallLibrary, it searches
/// already folded UTF-8 bytes, retaining native contiguous String
/// storage when it can be shared with Note. Replacing an entry neither copies
/// the library nor leaves dead bytes in an arena.
public struct ReaderSearchCorpus: Sendable {
    private struct Source: Equatable, Sendable {
        let id: UUID
        let title: String
        let summary: String
        let text: String
        let filename: String
        let metadata: String

        init(_ note: Note) {
            id = note.id
            title = note.title ?? ""
            summary = note.summary ?? ""
            text = note.text
            filename = note.fileURL.lastPathComponent
            metadata = note.metadataSearchText
        }
    }

    private struct Field: Sendable {
        /// Native contiguous UTF-8 storage. If normalization changes no bytes,
        /// this shares the Note's existing String rather than duplicating its
        /// metadata in a permanent Data allocation.
        let utf8: String
        let sharesSource: Bool
        /// Scalar boundaries inside a grapheme, relative to this field.
        let forbiddenBoundaries: [Int]

        init(_ source: String, alreadyLowercased: Bool = false, canShareSource: Bool = true) throws {
            try Task.checkCancellation()
            let folded = alreadyLowercased ? source : source.lowercased()
            let normalized = folded.precomposedStringWithCanonicalMapping
            let unchanged = source.utf8.elementsEqual(normalized.utf8)
            var storage = unchanged ? source : normalized
            storage.makeContiguousUTF8()
            utf8 = storage
            sharesSource = unchanged && canShareSource && source.isContiguousUTF8
            forbiddenBoundaries = try Self.graphemeBoundaries(in: storage)
        }

        /// Boundaries inside a character. A string whose every character is one
        /// scalar has none, so Cyrillic and ASCII skip Swift's grapheme walk.
        private static func graphemeBoundaries(in storage: String) throws -> [Int] {
            if try !needsGraphemeWalk(storage) { return [] }
            var forbidden: [Int] = []
            var offset = 0
            for (index, character) in storage.enumerated() {
                if index & 1023 == 0 { try Task.checkCancellation() }
                var first = true
                for scalar in character.unicodeScalars {
                    if !first { forbidden.append(offset) }
                    offset += scalar.utf8.count
                    first = false
                }
            }
            return forbidden
        }

        /// True when some character may contain more than one scalar: combining
        /// marks, ZWJ, variation selectors, flags, Hangul jamo, or CRLF.
        private static func needsGraphemeWalk(_ text: String) throws -> Bool {
            var sawNonASCII = false
            var previousWasCR = false
            var index = 0
            for byte in text.utf8 {
                if index & 65535 == 0 { try Task.checkCancellation() }
                index += 1
                if byte >= 0x80 {
                    sawNonASCII = true
                    break
                }
                if previousWasCR && byte == 0x0A { return true }
                previousWasCR = byte == 0x0D
            }
            if !sawNonASCII { return false }
            var seen = 0
            for scalar in text.unicodeScalars {
                if seen & 4095 == 0 { try Task.checkCancellation() }
                seen += 1
                if joinsGrapheme(scalar) { return true }
            }
            return false
        }

        private static func joinsGrapheme(_ scalar: Unicode.Scalar) -> Bool {
            if scalar.properties.isGraphemeExtend { return true }
            let value = scalar.value
            if value == 0x0D || value == 0x200C || value == 0x200D { return true }
            if value >= 0xFE00 && value <= 0xFE0F { return true }
            if value >= 0xE0100 && value <= 0xE01EF { return true }
            if value >= 0x1F1E6 && value <= 0x1F1FF { return true }
            if value >= 0xE0020 && value <= 0xE007F { return true }
            if value >= 0x1100 && value <= 0x11FF { return true }
            if value >= 0xA960 && value <= 0xA97F { return true }
            if value >= 0xD7B0 && value <= 0xD7FF { return true }
            return false
        }

        private init(utf8: String, sharesSource: Bool, forbiddenBoundaries: [Int]) {
            self.utf8 = utf8
            self.sharesSource = sharesSource
            self.forbiddenBoundaries = forbiddenBoundaries
        }

        /// A full journal reload can recreate an equal String in new storage.
        /// Rebind to that storage so keeping prepared entries does not retain a
        /// second old copy of all metadata. Reuse normalization and boundaries.
        func rebinding(to source: String) -> Field {
            var candidate = source
            candidate.makeContiguousUTF8()
            var prepared = utf8
            let sameBytes = candidate.withUTF8 { incoming in
                prepared.withUTF8 { existing in
                    incoming.count == existing.count && (incoming.isEmpty
                        || incoming.baseAddress == existing.baseAddress
                        || memcmp(incoming.baseAddress!, existing.baseAddress!, incoming.count) == 0)
                }
            }
            return Field(utf8: sameBytes ? candidate : utf8,
                         sharesSource: sameBytes && source.isContiguousUTF8,
                         forbiddenBoundaries: forbiddenBoundaries)
        }

        func contains(_ needle: Data) -> Bool {
            guard !utf8.isEmpty else { return false }
            var storage = utf8
            // The no-copy Data view never escapes withUTF8's pointer lifetime.
            // This uses the same Foundation byte search as an owned Data buffer.
            return storage.withUTF8 { buffer in
                let bytes = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer.baseAddress!),
                                 count: buffer.count, deallocator: .none)
                var remaining = 0..<buffer.count
                while !remaining.isEmpty,
                      let hit = bytes.range(of: needle, options: [], in: remaining) {
                    if !isForbidden(hit.lowerBound), !isForbidden(hit.upperBound) { return true }
                    remaining = (hit.lowerBound + 1)..<remaining.upperBound
                }
                return false
            }
        }

        private func isForbidden(_ offset: Int) -> Bool {
            var low = 0
            var high = forbiddenBoundaries.count
            while low < high {
                let mid = (low + high) / 2
                if forbiddenBoundaries[mid] < offset { low = mid + 1 } else { high = mid }
            }
            return low < forbiddenBoundaries.count && forbiddenBoundaries[low] == offset
        }
    }

    private struct Entry: Sendable {
        // Source strings share the Note's storage and let unchanged entries
        // bypass normalization. One small field array owns each prepared note;
        // replacing/deleting it immediately releases its transformed text.
        let source: Source
        let fields: [Field]

        init(_ source: Source) throws {
            self.source = source
            fields = try autoreleasepool {
                try [Field(source.title), Field(source.summary), Field(source.text),
                     Field(source.filename), Field(source.metadata, alreadyLowercased: true),
                     Field(source.id.uuidString, canShareSource: false)]
            }
        }

        private init(source: Source, fields: [Field]) {
            self.source = source
            self.fields = fields
        }

        func rebinding(to source: Source) -> Entry {
            let values = [source.title, source.summary, source.text, source.filename, source.metadata]
            var rebound = zip(fields, values).map { $0.rebinding(to: $1) }
            rebound.append(fields[5]) // UUID storage does not belong to Note.
            return Entry(source: source, fields: rebound)
        }

        func contains(_ needle: Data, field: Int) -> Bool { fields[field].contains(needle) }
    }

    private var entries: [Entry] = []
    private var positions: [UUID: Int] = [:]
    public init() {}
    public var count: Int { entries.count }
    /// Prepared UTF-8 payload, including bytes shared with existing Notes.
    public var byteCount: Int {
        entries.reduce(0) { total, entry in total + entry.fields.reduce(0) { $0 + $1.utf8.utf8.count } }
    }
    /// Additional text payload owned by the corpus (not a process footprint).
    public var additionalByteCount: Int {
        entries.reduce(0) { total, entry in
            total + entry.fields.reduce(0) { $0 + ($1.sharesSource ? 0 : $1.utf8.utf8.count) }
        }
    }

    /// Transactional: a cancellation keeps the previous complete corpus. Identity
    /// and field comparisons happen on the worker, never on MainActor. Reordering,
    /// flag changes and deletions reuse surviving buffers without re-encoding.
    @discardableResult
    public mutating func update(notes: [Note]) throws -> Int {
        var previous: [UUID: Int] = [:]
        for (index, entry) in entries.enumerated() { previous[entry.source.id] = index }
        var updated: [Entry] = []
        updated.reserveCapacity(notes.count)
        var rebuilt = 0
        for note in notes {
            try Task.checkCancellation()
            let source = Source(note)
            if let index = previous[source.id], entries[index].source == source {
                updated.append(entries[index].rebinding(to: source))
            } else {
                updated.append(try Entry(source))
                rebuilt += 1
            }
        }
        try Task.checkCancellation()
        entries = updated
        positions = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.source.id, $0.offset) })
        return rebuilt
    }

    /// The caller supplies an exhaustive delta only when order and count are unchanged.
    /// Prepare replacements before mutation so cancellation remains transactional.
    public mutating func update(notes: [Note], changedIDs: Set<UUID>) throws -> Int {
        guard notes.count == entries.count else { return try update(notes: notes) }
        var replacements: [(Int, Entry)] = []
        for id in changedIDs {
            try Task.checkCancellation()
            guard let index = positions[id], notes.indices.contains(index), notes[index].id == id else {
                return try update(notes: notes)
            }
            let source = Source(notes[index])
            let entry = entries[index].source == source ? entries[index].rebinding(to: source) : try Entry(source)
            replacements.append((index, entry))
        }
        try Task.checkCancellation()
        for (index, entry) in replacements { entries[index] = entry }
        return replacements.count
    }

    public static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().precomposedStringWithCanonicalMapping
    }

    /// Returns indices in note-array order, preserving Reader navigation order.
    public func searchIndices(
        query: String,
        searchInTitle: Bool = true,
        searchInSummary: Bool = true,
        searchInText: Bool = true,
        searchInId: Bool = true
    ) throws -> [Int] {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else { return Array(entries.indices) }
        let needle = Data(normalized.utf8)
        var hits: [Int] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            if (searchInTitle && entry.contains(needle, field: 0))
                || (searchInSummary && entry.contains(needle, field: 1))
                || (searchInText && (entry.contains(needle, field: 2)
                    || entry.contains(needle, field: 3) || entry.contains(needle, field: 4)))
                || (searchInId && entry.contains(needle, field: 5)) {
                hits.append(index)
            }
        }
        return hits
    }
}

/// Serializes corpus updates and shares the latest text matches between list
/// filtering and Return/Shift-Return. Caller revisions also cover note order and
/// flags; a cached hit can never be interpreted against a different note array.
public actor ReaderSearchWorker {
    public struct Result: Sendable {
        public let revision: UInt64
        public let query: String
        public let hits: [Int]
        public let visibleIndices: [Int]
        public let rebuiltEntries: Int
    }

    private var corpus = ReaderSearchCorpus()
    private var revision: UInt64?
    private var cachedQuery: String?
    private var cachedHits: [Int] = []
    public init() {}

    /// The UI owns this operation per note revision, separately from queries.
    /// Canceling an obsolete query must not restart a still useful cold build.
    @discardableResult
    public func prepare(notes: [Note], revision: UInt64, changedIDs: Set<UUID>? = nil) throws -> Int {
        try Task.checkCancellation()
        guard self.revision != revision else { return 0 }
        let rebuilt: Int
        if let changedIDs, let previous = self.revision, previous &+ 1 == revision {
            rebuilt = try corpus.update(notes: notes, changedIDs: changedIDs)
        } else { rebuilt = try corpus.update(notes: notes) }
        self.revision = revision
        cachedQuery = nil
        return rebuilt
    }

    public func search(notes: [Note], revision: UInt64, filter: NoteFilter) throws -> Result {
        let rebuilt = try prepare(notes: notes, revision: revision)
        let query = ReaderSearchCorpus.normalize(filter.query)
        let hits: [Int]
        if query == cachedQuery {
            hits = cachedHits
        } else {
            hits = query.isEmpty ? [] : try corpus.searchIndices(query: query)
            cachedQuery = query
            cachedHits = hits
        }
        try Task.checkCancellation()
        let visible = NotesQueryService().computeVisibleIndices(
            notes: notes, filter: filter, textMatchIndices: hits
        )
        try Task.checkCancellation()
        return Result(revision: revision, query: query, hits: hits,
                      visibleIndices: visible, rebuiltEntries: rebuilt)
    }
}
