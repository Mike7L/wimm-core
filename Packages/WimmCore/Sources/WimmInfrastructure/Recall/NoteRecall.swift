import Foundation
import WimmDomain

/// The slice of a library note an outside agent may read: what was said or
/// written, when, and where the original lives. Read-only by construction —
/// nothing here can write a sidecar.
public struct RecallNote: Sendable, Equatable, Codable {
    public let id: String
    public let date: Date
    public let kind: String
    public let title: String?
    public let summary: String?
    public let text: String
    public let attachmentTexts: [String]
    public let filePath: String
    /// Audio length in seconds, from the sidecar.
    public let duration: Double?
    /// `speech` / `no_speech` / `skipped:<reason>` / `failed`; nil for non-audio notes.
    public let speech: String?
    /// Characters of the main transcript (audio) or of the note text.
    public let chars: Int?
    /// Origin platform: "iPhone", "macOS".
    public let device: String?
    /// When the note's file or its sidecar last changed on this Mac — an
    /// edit, a new transcript, analysis, an attachment, or a sync stamp.
    /// nil when it was not known at build time.
    public let updated: Date?
    var fingerprintSnapshot: NoteFingerprintSnapshot? = nil

    public init(
        id: String,
        date: Date,
        kind: String,
        title: String?,
        summary: String?,
        text: String,
        attachmentTexts: [String] = [],
        filePath: String,
        duration: Double? = nil,
        speech: String? = nil,
        chars: Int? = nil,
        device: String? = nil,
        updated: Date? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.summary = summary
        self.text = text
        self.attachmentTexts = attachmentTexts
        self.filePath = filePath
        self.duration = duration
        self.speech = speech
        self.chars = chars
        self.device = device
        self.updated = updated
    }

    /// `sidecar` is the note's parsed `.meta.json`; the list facts come from
    /// it rather than from `Note`, whose duration ignores the recorder's own.
    public init(note: Note, sidecar: [String: Any] = [:], updated: Date? = nil) {
        let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = RecallSidecar(sidecar)
        let isAudio = FileStore.isAudioFile(note.fileURL)
        var speech = meta.speech(isAudio: isAudio)
        // Old notes keep the transcript outside the sidecar; NoteBuilder found it.
        if speech == "failed", !note.isFailed, note.transcriptionSpeechStatus != .noSpeech, !text.isEmpty {
            speech = "speech"
        }
        let body = text.isEmpty ? (note.refinedText ?? "") : text
        self.init(
            id: note.id.uuidString,
            date: note.absoluteDate,
            kind: Self.kind(of: note.fileURL),
            title: note.title?.nilIfBlank,
            summary: note.summary?.nilIfBlank,
            text: body,
            attachmentTexts: note.attachments.compactMap { $0.extractedText?.nilIfBlank },
            filePath: note.fileURL.path,
            duration: isAudio ? meta.duration ?? (note.duration > 0 ? note.duration : nil) : nil,
            speech: speech,
            chars: isAudio ? (speech == "speech" ? (meta.transcript ?? text).count : 0) : body.count,
            device: meta.platform ?? meta.deviceModel,
            updated: updated
        )
    }

    func withFingerprintSnapshot(_ snapshot: NoteFingerprintSnapshot?) -> RecallNote {
        var copy = self
        copy.fingerprintSnapshot = snapshot
        return copy
    }

    /// UTF-8 bytes this note takes in a `RecallLibrary` buffer.
    var rawByteCount: Int {
        id.utf8.count + filePath.utf8.count + (title?.utf8.count ?? 0) + (summary?.utf8.count ?? 0)
            + text.utf8.count + attachmentTexts.reduce(0) { $0 + $1.utf8.count }
    }

    /// The lowercased text search runs over. Folding a whole library is
    /// seconds of CPU, so a load does it once, on the build workers.
    func folded() -> FoldedText {
        FoldedText(
            id: id.lowercased(),
            title: (title ?? "").lowercased(),
            summary: (summary ?? "").lowercased(),
            body: body.lowercased()
        )
    }

    /// Nothing worth reading: a silent, skipped or failed recording, or audio with no text.
    var isEmpty: Bool { Self.isEmpty(kind: kind, speech: speech, chars: chars) }

    static func isEmpty(kind: String, speech: String?, chars: Int?) -> Bool {
        if let speech, speech != "speech" { return true }
        return kind == "audio" && chars == 0
    }

    /// Text plus attachment text, as the snippet shows it.
    var body: String { ([text] + attachmentTexts).joined(separator: "\n") }

    /// The shared kind table (`NoteContent`); recall keeps it as a string.
    static func kind(of url: URL) -> String {
        NoteContent.kind(of: url).rawValue
    }
}

/// A note's text lowercased, in the parts the folded buffer keeps apart.
struct FoldedText: Sendable {
    let id: String
    let title: String
    let summary: String
    let body: String

    var byteCount: Int { id.utf8.count + title.utf8.count + summary.utf8.count + body.utf8.count }
}

/// Every note of one load, with all of their text in two contiguous byte
/// buffers — as written, and lowercased for search — and only ranges per note.
///
/// Holding each note's text in its own `String`s left a full load at ~275 MB
/// for ~75 MB of live text: the strings sat interleaved with the freed
/// sidecar dictionaries of the build, so almost no page could go back to the
/// system (72% fragmentation). Two large buffers live outside that heap.
public struct RecallLibrary: Sendable {
    struct Entry: Sendable {
        let date: Date
        let updated: Date?
        let fingerprintSnapshot: NoteFingerprintSnapshot?
        let kind: String
        let duration: Double?
        let speech: String?
        let chars: Int?
        let device: String?
        let id: Range<Int>
        let path: Range<Int>
        let title: Range<Int>?
        let summary: Range<Int>?
        let text: Range<Int>
        let attachments: [Range<Int>]
        // In `folded`:
        let foldedID: Range<Int>
        let foldedTitle: Range<Int>
        let foldedSummary: Range<Int>
        let foldedBody: Range<Int>
    }

    let raw: [UInt8]
    let folded: [UInt8]
    let entries: [Entry]

    public init(_ notes: [RecallNote]) {
        var builder = Builder()
        for note in notes { builder.append(note) }
        self = builder.build()
    }

    public var count: Int { entries.count }

    /// Path to the fingerprint captured while this library was built. The byte-buffer
    /// entries stay inside the module.
    public func fingerprintSnapshotsByPath() -> [String: NoteFingerprintSnapshot] {
        Dictionary(entries.compactMap { entry in
            entry.fingerprintSnapshot.map { (string(entry.path), $0) }
        }, uniquingKeysWith: { _, latest in latest })
    }

    public func indexOfSidecar(matching target: URL) -> Int? {
        entries.indices.first { index in
            let file = URL(fileURLWithPath: string(entries[index].path))
            let sidecar = FileStore.metadataURL(forRecordingURL: file)
            return sidecar.lastPathComponent == target.lastPathComponent
                && sidecar.resolvingSymlinksInPath() == target
        }
    }

    public subscript(index: Int) -> RecallNote {
        let e = entries[index]
        return RecallNote(
            id: string(e.id),
            date: e.date,
            kind: e.kind,
            title: e.title.map(string),
            summary: e.summary.map(string),
            text: string(e.text),
            attachmentTexts: e.attachments.map(string),
            filePath: string(e.path),
            duration: e.duration,
            speech: e.speech,
            chars: e.chars,
            device: e.device,
            updated: e.updated
        ).withFingerprintSnapshot(e.fingerprintSnapshot)
    }

    func rawByteCount(of index: Int) -> Int {
        let e = entries[index]
        return e.id.count + e.path.count + (e.title?.count ?? 0) + (e.summary?.count ?? 0)
            + e.text.count + e.attachments.reduce(0) { $0 + $1.count }
    }

    func foldedByteCount(of index: Int) -> Int {
        let e = entries[index]
        return e.foldedID.count + e.foldedTitle.count + e.foldedSummary.count + e.foldedBody.count
    }

    func string(_ range: Range<Int>) -> String {
        raw.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[range]), as: UTF8.self) }
    }

    /// A note as bytes: its fields' UTF-8 back to back — id, path, title,
    /// summary, text, attachments, then the folded id, title, summary and
    /// body — and the byte length of each. This is how the build child hands
    /// notes over, so the server never makes a `String` of their text.
    struct Layout: Codable {
        let date: Date
        let updated: Date?
        let fingerprintSnapshot: NoteFingerprintSnapshot?
        let kind: String
        let duration: Double?
        let speech: String?
        let chars: Int?
        let device: String?
        let id: Int
        let path: Int
        let title: Int?
        let summary: Int?
        let text: Int
        let attachments: [Int]
        let foldedID: Int
        let foldedTitle: Int
        let foldedSummary: Int
        let foldedBody: Int

        var rawBytes: Int { id + path + (title ?? 0) + (summary ?? 0) + text + attachments.reduce(0, +) }
        var foldedBytes: Int { foldedID + foldedTitle + foldedSummary + foldedBody }
        var payloadBytes: Int { rawBytes + foldedBytes }

        var isValid: Bool {
            ([id, path, title ?? 0, summary ?? 0, text, foldedID, foldedTitle, foldedSummary, foldedBody]
                + attachments).allSatisfy { $0 >= 0 }
        }

        static func encode(_ note: RecallNote) -> (layout: Layout, payload: Data) {
            let folded = note.folded()
            var payload = Data()
            func put(_ s: String) -> Int {
                let before = payload.count
                payload.append(contentsOf: s.utf8)
                return payload.count - before
            }
            let layout = Layout(
                date: note.date,
                updated: note.updated,
                fingerprintSnapshot: note.fingerprintSnapshot,
                kind: note.kind,
                duration: note.duration,
                speech: note.speech,
                chars: note.chars,
                device: note.device,
                id: put(note.id),
                path: put(note.filePath),
                title: note.title.map(put),
                summary: note.summary.map(put),
                text: put(note.text),
                attachments: note.attachmentTexts.map(put),
                foldedID: put(folded.id),
                foldedTitle: put(folded.title),
                foldedSummary: put(folded.summary),
                foldedBody: put(folded.body)
            )
            return (layout, payload)
        }
    }

    struct Builder {
        private var raw: [UInt8] = []
        private var folded: [UInt8] = []
        private var entries: [Entry] = []

        init(rawCapacity: Int = 0, foldedCapacity: Int = 0) {
            raw.reserveCapacity(rawCapacity)
            folded.reserveCapacity(foldedCapacity)
        }

        mutating func append(_ note: RecallNote) {
            append(note, folded: note.folded())
        }

        /// `text` must be `note.folded()`, computed wherever it is cheapest.
        mutating func append(_ note: RecallNote, folded text: FoldedText) {
            func put(_ s: String) -> Range<Int> {
                let start = raw.count
                raw.append(contentsOf: s.utf8)
                return start..<raw.count
            }
            func fold(_ s: String) -> Range<Int> {
                let start = folded.count
                folded.append(contentsOf: s.utf8)
                return start..<folded.count
            }
            entries.append(Entry(
                date: note.date,
                updated: note.updated,
                fingerprintSnapshot: note.fingerprintSnapshot,
                kind: note.kind,
                duration: note.duration,
                speech: note.speech,
                chars: note.chars,
                device: note.device,
                id: put(note.id),
                path: put(note.filePath),
                title: note.title.map(put),
                summary: note.summary.map(put),
                text: put(note.text),
                attachments: note.attachmentTexts.map(put),
                foldedID: fold(text.id),
                foldedTitle: fold(text.title),
                foldedSummary: fold(text.summary),
                foldedBody: fold(text.body)
            ))
        }

        /// `payload` holds exactly `layout.payloadBytes` bytes.
        mutating func append(_ layout: Layout, payload: UnsafeRawBufferPointer) {
            var offset = 0
            func take(_ count: Int, into buffer: inout [UInt8]) -> Range<Int> {
                let start = buffer.count
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: payload[offset..<offset + count]))
                offset += count
                return start..<buffer.count
            }
            let id = take(layout.id, into: &raw)
            let path = take(layout.path, into: &raw)
            let title = layout.title.map { take($0, into: &raw) }
            let summary = layout.summary.map { take($0, into: &raw) }
            let text = take(layout.text, into: &raw)
            let attachments = layout.attachments.map { take($0, into: &raw) }
            entries.append(Entry(
                date: layout.date,
                updated: layout.updated,
                fingerprintSnapshot: layout.fingerprintSnapshot,
                kind: layout.kind,
                duration: layout.duration,
                speech: layout.speech,
                chars: layout.chars,
                device: layout.device,
                id: id,
                path: path,
                title: title,
                summary: summary,
                text: text,
                attachments: attachments,
                foldedID: take(layout.foldedID, into: &folded),
                foldedTitle: take(layout.foldedTitle, into: &folded),
                foldedSummary: take(layout.foldedSummary, into: &folded),
                foldedBody: take(layout.foldedBody, into: &folded)
            ))
        }

        /// Copies one note's bytes from an earlier load without rebuilding it.
        mutating func append(_ index: Int, of library: RecallLibrary) {
            let e = library.entries[index]
            func copyRaw(_ r: Range<Int>) -> Range<Int> {
                let start = raw.count
                raw.append(contentsOf: library.raw[r])
                return start..<raw.count
            }
            func copyFolded(_ r: Range<Int>) -> Range<Int> {
                let start = folded.count
                folded.append(contentsOf: library.folded[r])
                return start..<folded.count
            }
            entries.append(Entry(
                date: e.date,
                updated: e.updated,
                fingerprintSnapshot: e.fingerprintSnapshot,
                kind: e.kind,
                duration: e.duration,
                speech: e.speech,
                chars: e.chars,
                device: e.device,
                id: copyRaw(e.id),
                path: copyRaw(e.path),
                title: e.title.map(copyRaw),
                summary: e.summary.map(copyRaw),
                text: copyRaw(e.text),
                attachments: e.attachments.map(copyRaw),
                foldedID: copyFolded(e.foldedID),
                foldedTitle: copyFolded(e.foldedTitle),
                foldedSummary: copyFolded(e.foldedSummary),
                foldedBody: copyFolded(e.foldedBody)
            ))
        }

        var count: Int { entries.count }

        func build() -> RecallLibrary {
            RecallLibrary(raw: raw, folded: folded, entries: entries)
        }
    }

    private init(raw: [UInt8], folded: [UInt8], entries: [Entry]) {
        self.raw = raw
        self.folded = folded
        self.entries = entries
    }
}

public struct RecallHit: Sendable, Equatable {
    public let note: RecallNote
    public let score: Int
    public let snippet: String
}

/// Lexical recall over the whole library: a linear scan, as everywhere else
/// (see docs/Search_Index_Decision.md). Every query term must occur
/// somewhere in the note; title and summary matches weigh more than body
/// matches, newer notes win ties.
public enum NoteRecall {

    public static func search(
        _ library: RecallLibrary,
        query: String,
        since: Date? = nil,
        until: Date? = nil,
        updatedSince: Date? = nil,
        limit: Int = 10
    ) -> [RecallHit] {
        searchPage(
            library, query: query, since: since, until: until, updatedSince: updatedSince, offset: 0, limit: limit
        ).hits
    }

    /// One page of `search`, plus how many notes match in all.
    public static func searchPage(
        _ library: RecallLibrary,
        query: String,
        since: Date? = nil,
        until: Date? = nil,
        updatedSince: Date? = nil,
        offset: Int = 0,
        limit: Int = 10
    ) -> (hits: [RecallHit], total: Int) {
        let textTerms = Self.terms(of: query)
        let terms = textTerms.map { Array($0.utf8) }
        var scored: [(index: Int, score: Int)] = []
        library.folded.withUnsafeBufferPointer { folded in
            for (i, e) in library.entries.enumerated()
            where inRange(e.date, since: since, until: until) && updated(e, since: updatedSince) {
                var score = 0
                var matchedAll = true
                for term in terms {
                    let t = occurrences(of: term, in: folded, e.foldedTitle)
                    let s = occurrences(of: term, in: folded, e.foldedSummary)
                    let b = occurrences(of: term, in: folded, e.foldedBody, cap: 10)
                    if t + s + b == 0 && !hasPrefix(folded, e.foldedID, term) {
                        matchedAll = false
                        break
                    }
                    score += t * 5 + s * 3 + b
                }
                if matchedAll { scored.append((i, score)) }
            }
        }
        scored.sort {
            $0.score != $1.score
                ? $0.score > $1.score
                : library.entries[$0.index].date > library.entries[$1.index].date
        }
        // A common word matches thousands of notes; text only for the ones returned.
        let hits = scored.dropFirst(max(0, offset)).prefix(max(0, limit)).map {
            let note = library[$0.index]
            return RecallHit(note: note, score: $0.score, snippet: snippet(note.body, terms: textTerms))
        }
        return (hits, scored.count)
    }

    public static func recent(
        _ library: RecallLibrary,
        since: Date? = nil,
        until: Date? = nil,
        updatedSince: Date? = nil,
        includeEmpty: Bool = true,
        limit: Int = 20
    ) -> [RecallNote] {
        recentPage(
            library, since: since, until: until, updatedSince: updatedSince, includeEmpty: includeEmpty,
            offset: 0, limit: limit
        ).notes
    }

    /// One page of `recent`, plus how many notes the window holds in all.
    public static func recentPage(
        _ library: RecallLibrary,
        since: Date? = nil,
        until: Date? = nil,
        updatedSince: Date? = nil,
        includeEmpty: Bool = true,
        offset: Int = 0,
        limit: Int = 20
    ) -> (notes: [RecallNote], total: Int) {
        let matching = library.entries.indices
            .filter {
                let e = library.entries[$0]
                return inRange(e.date, since: since, until: until) && updated(e, since: updatedSince)
                    && (includeEmpty || !RecallNote.isEmpty(kind: e.kind, speech: e.speech, chars: e.chars))
            }
            .sorted { library.entries[$0].date > library.entries[$1].date }
        return (matching.dropFirst(max(0, offset)).prefix(max(0, limit)).map { library[$0] }, matching.count)
    }

    /// Where a `changed` listing stopped: the last note handed out, by its
    /// change time and id. Keyset rather than offset, so notes that change
    /// while an agent pages through move to the end instead of shifting the
    /// pages under it.
    public struct ChangeCursor: Equatable, Sendable {
        public let updated: Date
        public let id: String
        /// The `since` of the walk this cursor belongs to. A next page asked
        /// with the cursor alone keeps counting `total` from it — without it
        /// `total` silently became the whole library.
        public let since: Date?

        public init(updated: Date, id: String, since: Date? = nil) {
            self.updated = updated
            self.id = id
            self.since = since
        }

        /// `<µs since 1970>.<since in µs, or ->.<id>` — opaque to the agent.
        public var token: String {
            "\(Self.micros(updated)).\(since.map { String(Self.micros($0)) } ?? "-").\(id)"
        }

        public init?(token: String) {
            func date(_ s: Substring) -> Date? { Int64(s).map { Date(timeIntervalSince1970: Double($0) / 1e6) } }
            let parts = token.split(separator: ".", maxSplits: 2)
            guard parts.count >= 2, let updated = date(parts[0]) else { return nil }
            if parts.count == 3, parts[1] == "-" || date(parts[1]) != nil, !parts[2].isEmpty {
                self.init(updated: updated, id: String(parts[2]), since: date(parts[1]))
            } else {
                // `<µs>.<id>`, as the first release handed out.
                let id = token[token.index(after: token.firstIndex(of: ".")!)...]
                guard !id.isEmpty else { return nil }
                self.init(updated: updated, id: String(id))
            }
        }

        private static func micros(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1e6).rounded()) }
    }

    /// Notes whose file or sidecar changed at or after `since`, oldest
    /// change first (or newest first with `newestFirst`; the cursor then walks
    /// backwards), so an agent can walk them page by page and keep the
    /// last cursor as its watermark. `total` counts every change since
    /// `since`, `remaining` those after this page. Notes with an unknown
    /// change time are never listed.
    public static func changed(
        _ library: RecallLibrary,
        since: Date?,
        after cursor: ChangeCursor? = nil,
        limit: Int = 50,
        newestFirst: Bool = false,
        include: ((_ filePath: String) -> Bool)? = nil
    ) -> (notes: [RecallNote], total: Int, remaining: Int, next: ChangeCursor?) {
        // Ids compare in the same micro-precision the cursor round-trips through.
        func micros(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1e6).rounded()) }
        let all = library.entries.indices.compactMap { i -> (index: Int, at: Int64, id: String)? in
            guard let updated = library.entries[i].updated else { return nil }
            if let since, updated < since { return nil }
            if let include, !include(library.string(library.entries[i].path)) { return nil }
            return (i, micros(updated), library.string(library.entries[i].id))
        }.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
        let after = cursor.map { c in (micros(c.updated), c.id) }
        var pending = after.map { a in
            newestFirst
                ? all.filter { $0.at < a.0 || ($0.at == a.0 && $0.id < a.1) }
                : all.filter { $0.at > a.0 || ($0.at == a.0 && $0.id > a.1) }
        } ?? all
        if newestFirst { pending.reverse() }
        let page = pending.prefix(max(0, limit))
        let notes = page.map { library[$0.index] }
        let remaining = pending.count - page.count
        let next = notes.last.flatMap { last in last.updated.map { ChangeCursor(updated: $0, id: last.id, since: since) } }
        return (notes, all.count, remaining, next)
    }

    /// A note id (or prefix), or the note's file name — `Wimm_…_BD002026.m4a`,
    /// its `.meta.json`, or the name without extension. Agents keep registries
    /// by file name; the id is derived from the full path.
    public static func find(_ library: RecallLibrary, reference: String) -> RecallNote? {
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let note = find(library, id: ref) { return note }
        var name = (ref as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        if name.hasSuffix(".meta.json") { name = String(name.dropLast(".meta.json".count)) }
        var exact: [Int] = []
        var byStem: [Int] = []
        for i in library.entries.indices {
            let file = (library.string(library.entries[i].path) as NSString).lastPathComponent
            if file == name { exact.append(i) } else if (file as NSString).deletingPathExtension == name { byStem.append(i) }
        }
        let matches = exact.isEmpty ? byStem : exact
        return matches.count == 1 ? library[matches[0]] : nil
    }

    /// Full id or any unambiguous prefix of it (the CLI prints short ids).
    public static func find(_ library: RecallLibrary, id: String) -> RecallNote? {
        let needle = Array(id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        guard !needle.isEmpty else { return nil }
        let matches: [Int] = library.folded.withUnsafeBufferPointer { folded in
            var prefixed: [Int] = []
            for (i, e) in library.entries.enumerated() where hasPrefix(folded, e.foldedID, needle) {
                if e.foldedID.count == needle.count { return [i] }
                prefixed.append(i)
            }
            return prefixed
        }
        return matches.count == 1 ? library[matches[0]] : nil
    }

    // MARK: - Helpers

    static func terms(of query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(stem)
    }

    /// A crude stem so inflected words still meet: "подписка" must find
    /// "подписку", "заметки" must find "заметок". Cyrillic words of 5+
    /// letters lose up to two trailing vowels/soft signs (never below 4
    /// letters); Latin ones a plural "s". Matching is by substring, so the
    /// stem catches every ending that follows it.
    static func stem(_ word: String) -> String {
        let letters = Array(word)
        guard letters.count >= 5 else { return word }
        if letters.contains(where: { ("а"..."я").contains($0) || $0 == "ё" }) {
            var cut = letters
            while cut.count > 4, letters.count - cut.count < 2, let last = cut.last,
                  "аеёиоуыэюяьй".contains(last) {
                cut.removeLast()
            }
            return String(cut)
        }
        if letters.last == "s", letters.dropLast().last != "s" {
            return String(letters.dropLast())
        }
        return word
    }

    static func inRange(_ date: Date, since: Date?, until: Date?) -> Bool {
        if let since, date < since { return false }
        if let until, date >= until { return false }
        return true
    }

    /// A note with no known write time never passes an `updated_since` filter.
    static func updated(_ entry: RecallLibrary.Entry, since: Date?) -> Bool {
        guard let since else { return true }
        guard let updated = entry.updated else { return false }
        return updated >= since
    }

    static func hasPrefix(_ buffer: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, _ prefix: [UInt8]) -> Bool {
        guard range.count >= prefix.count, let base = buffer.baseAddress else { return false }
        return prefix.withUnsafeBufferPointer { p in
            memcmp(base + range.lowerBound, p.baseAddress!, p.count) == 0
        }
    }

    /// `memmem` over already-lowercased UTF-8.
    static func occurrences(
        of term: [UInt8],
        in buffer: UnsafeBufferPointer<UInt8>,
        _ range: Range<Int>,
        cap: Int = .max
    ) -> Int {
        guard !term.isEmpty, !range.isEmpty, let base = buffer.baseAddress else { return 0 }
        return term.withUnsafeBufferPointer { n in
            var count = 0
            var offset = range.lowerBound
            while count < cap, offset < range.upperBound,
                  let found = memmem(base + offset, range.upperBound - offset, n.baseAddress!, n.count) {
                count += 1
                offset = UnsafeRawPointer(found) - UnsafeRawPointer(base) + n.count
            }
            return count
        }
    }

    /// Same, for a standalone string.
    static func occurrences(of term: String, in text: String, cap: Int = .max) -> Int {
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer {
            occurrences(of: Array(term.utf8), in: $0, 0..<bytes.count, cap: cap)
        }
    }

    /// ~240 characters around the first body match, or the opening of the
    /// body when the hit was in the title/summary only.
    static func snippet(_ body: String, terms: [String], radius: Int = 120) -> String {
        let flat = body.replacingOccurrences(of: "\n", with: " ")
        let lower = flat.lowercased()
        let anchor = terms.lazy.compactMap { lower.range(of: $0) }.first
        guard let anchor else {
            return flat.count > radius * 2 ? String(flat.prefix(radius * 2)) + "…" : flat
        }
        let offset = lower.distance(from: lower.startIndex, to: anchor.lowerBound)
        let startOffset = max(0, offset - radius)
        let endOffset = min(flat.count, offset + radius)
        let start = flat.index(flat.startIndex, offsetBy: startOffset)
        let end = flat.index(flat.startIndex, offsetBy: endOffset)
        return (startOffset > 0 ? "…" : "") + String(flat[start..<end]) + (endOffset < flat.count ? "…" : "")
    }
}

/// Loads the real library — the same `FileRepository` listing and
/// `NoteBuilder` the Reader uses — and keeps it warm between agent calls.
/// A note is rebuilt only when its file or sidecar changed since the last
/// load; unchanged ones are copied over byte for byte.
///
/// Building parses every changed sidecar into short-lived dictionaries. In a
/// long-lived process those pages stay dirty after they are freed — on macOS
/// 26 `malloc_zone_pressure_relief` hands back nothing — so a full load left
/// the server at ~300 MB for ~95 MB of text. `wimm-cli mcp` therefore builds
/// in a child process (`.subprocess`) that streams finished notes back and
/// takes the garbage with it when it exits.
public actor LibraryRecallSource {
    public enum BuildMode: Sendable {
        case inProcess
        /// Runs `executable arguments…`, which must call `serveBuild`.
        case subprocess(executable: URL, arguments: [String])
    }

    /// Sidecar reads go through an actor `MetadataRepository`, which
    /// serializes them; one repository per worker lets them overlap.
    static let buildWorkers = 8

    private let buildMode: BuildMode
    /// Opt-in for packet preparation; ordinary search avoids this extra work.
    private let includeFingerprints: Bool
    private let cacheDirectory: URL?
    private var cacheAttempted = false
    public private(set) var restoredFromDisk = false
    public private(set) var rebuiltNoteCount = 0
    private let fileRepository = FileRepository()
    /// The note files of the last load and what was known about each.
    private var known = KnownFiles()

    /// A note's file and sidecar mtimes.
    struct Stamp: Equatable, Codable {
        let file: Date?
        let sidecar: Date?
        var inputs: [NoteFingerprintSnapshot.Stamp]? = nil
    }

    /// The note files of one load as a few contiguous arrays: their paths
    /// back to back, and per file its stamp and its slot in `library`. Held
    /// as `URL` keys of a dictionary, the ~7k survivors of each ~25k-entry
    /// directory listing stayed scattered over the heap and kept ~40 MB of
    /// freed pages from going back to the system.
    struct KnownFiles: Codable {
        private var bytes: [UInt8] = []
        private var ranges: [Range<Int>] = []
        private(set) var stamps: [Stamp] = []
        /// Index in `library`; -1 for a canceled note.
        private(set) var slots: [Int] = []

        init() {}

        init(paths: [String], stamps: [Stamp], slots: [Int]) {
            bytes.reserveCapacity(paths.reduce(0) { $0 + $1.utf8.count })
            ranges.reserveCapacity(paths.count)
            for path in paths {
                let start = bytes.count
                bytes.append(contentsOf: path.utf8)
                ranges.append(start..<bytes.count)
            }
            self.stamps = stamps
            self.slots = slots
        }

        var count: Int { ranges.count }
        var isEmpty: Bool { ranges.isEmpty }
        var hasValidStorage: Bool {
            ranges.count == stamps.count && ranges.count == slots.count &&
                ranges.allSatisfy { $0.lowerBound >= 0 && $0.upperBound <= bytes.count }
        }

        func path(_ index: Int) -> String {
            bytes.withUnsafeBufferPointer {
                String(decoding: UnsafeBufferPointer(rebasing: $0[ranges[index]]), as: UTF8.self)
            }
        }

        /// Path → index; built for one reload and dropped with it.
        func index() -> [String: Int] {
            var out: [String: Int] = [:]
            out.reserveCapacity(count)
            for i in 0..<count { out[path(i)] = i }
            return out
        }
    }

    private var library = RecallLibrary([])
    private var inFlight: Task<RecallLibrary, Never>?
    private var lastLoadAt: Date?
    /// An agent fires several calls in a row (search, then get_note); one
    /// library check serves the whole burst.
    private let freshness: TimeInterval = 5

    public init(buildMode: BuildMode = .inProcess, includeFingerprints: Bool = false, cacheDirectory: URL? = nil) {
        self.buildMode = buildMode
        self.includeFingerprints = includeFingerprints
        self.cacheDirectory = cacheDirectory
    }

    /// Concurrent callers (the startup prewarm and the first tool call)
    /// share one load instead of each building the library.
    public func load() async -> RecallLibrary {
        lastUsedAt = Date()
        if let lastLoadAt, Date().timeIntervalSince(lastLoadAt) < freshness { return library }
        if let inFlight { return await inFlight.value }
        let task = Task { await self.reload() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        lastLoadAt = Date()
        return result
    }

    private var lastUsedAt: Date?

    /// Drops the loaded library when nobody has asked for it for `interval`.
    /// A long-lived server (one per agent session) otherwise keeps ~150–190 MB
    /// of note text for sessions that stopped using Wimm; the next call
    /// rebuilds it. Returns whether anything was released.
    @discardableResult
    public func releaseIfIdle(after interval: TimeInterval) -> Bool {
        guard inFlight == nil, !known.isEmpty,
              let lastUsedAt, Date().timeIntervalSince(lastUsedAt) >= interval else { return false }
        library = RecallLibrary([])
        known = KnownFiles()
        snapshot = nil
        lastLoadAt = nil
        cacheAttempted = false
        restoredFromDisk = false
        return true
    }

    /// The recordings directories as of the last load.
    private var snapshot: DirectoryFingerprint?

    /// Order-independent hashes of a directory listing: of its names, and of
    /// names with mtimes — two integers rather than ~25k kept path strings.
    struct DirectoryFingerprint: Equatable {
        var count = 0
        var names = 0
        var entries = 0

        init(_ mtimes: [String: Date]) {
            count = mtimes.count
            for (path, date) in mtimes {
                names &+= path.hashValue
                var hasher = Hasher()
                hasher.combine(path)
                hasher.combine(date)
                entries &+= hasher.finalize()
            }
        }
    }

    private func reload() async -> RecallLibrary {
        if !cacheAttempted {
            cacheAttempted = true
            restoreCache()
        }
        rebuiltNoteCount = 0
        // One listing with mtimes per directory answers "did anything
        // change?". The note listing and per-note stamps behind it cost
        // ~1.5 s, and every agent question after an idle pause used to pay it.
        let mtimes = Self.modificationDates(in: Self.libraryDirectories())
        let current = DirectoryFingerprint(mtimes)
        if !known.isEmpty, current == snapshot, !includeFingerprints { return library }
        let paths: [String]
        if !known.isEmpty, current.count == snapshot?.count, current.names == snapshot?.names {
            // `FileRepository` derives the listing from the names alone.
            paths = (0..<known.count).map(known.path)
        } else {
            paths = await fileRepository.recordings(order: .ascending).map(\.path)
            // Its cached copy would be one more set of scattered survivors.
            await fileRepository.invalidateCache()
        }
        snapshot = current

        let previousIndex = known.index()
        var stamps: [Stamp] = []
        stamps.reserveCapacity(paths.count)
        var slots = [Int](repeating: -1, count: paths.count)
        var stale: [Int] = []
        var kept: [(file: Int, slot: Int)] = []
        for (i, path) in paths.enumerated() {
            let stamp = Stamp(
                file: mtimes[path],
                sidecar: mtimes[FileStore.metadataURL(forRecordingURL: URL(fileURLWithPath: path)).path],
                inputs: includeFingerprints ? NoteFingerprintSnapshot.stamps(for: URL(fileURLWithPath: path)) : nil
            )
            stamps.append(stamp)
            if let old = previousIndex[path], known.stamps[old] == stamp {
                if known.slots[old] >= 0 { kept.append((i, known.slots[old])) }
            } else {
                stale.append(i)
            }
        }
        if stale.isEmpty && previousIndex.count == paths.count { return library }

        let keptRaw = kept.reduce(0) { $0 + library.rawByteCount(of: $1.slot) }
        let keptFolded = kept.reduce(0) { $0 + library.foldedByteCount(of: $1.slot) }
        let previous = library

        func start(rawCapacity: Int, foldedCapacity: Int) -> RecallLibrary.Builder {
            var builder = RecallLibrary.Builder(
                rawCapacity: keptRaw + rawCapacity, foldedCapacity: keptFolded + foldedCapacity)
            for (file, slot) in kept {
                slots[file] = builder.count
                builder.append(slot, of: previous)
            }
            return builder
        }

        let staleURLs = stale.map { URL(fileURLWithPath: paths[$0]) }
        rebuiltNoteCount = staleURLs.count
        var builder: RecallLibrary.Builder?
        if case let .subprocess(executable, arguments) = buildMode {
            builder = await buildInChild(
                staleURLs, executable: executable, arguments: arguments,
                start: start,
                record: { position, slot in slots[stale[position]] = slot ?? -1 }
            )
            if builder == nil { slots = [Int](repeating: -1, count: paths.count) }
        }
        if builder == nil {
            // In-process: tests, and the fallback when the child fails.
            let built = await Self.build(staleURLs, includeFingerprints: includeFingerprints) { position, _, note in
                (position: position, note: note, folded: note?.folded())
            }
            var b = start(
                rawCapacity: built.reduce(0) { $0 + ($1.note?.rawByteCount ?? 0) },
                foldedCapacity: built.reduce(0) { $0 + ($1.folded?.byteCount ?? 0) }
            )
            for item in built {
                if let note = item.note, let folded = item.folded {
                    slots[stale[item.position]] = b.count
                    b.append(note, folded: folded)
                }
            }
            builder = b
        }
        library = builder!.build()
        known = KnownFiles(paths: paths, stamps: stamps, slots: slots)
        saveCache()
        return library
    }

    private struct CacheHeader: Codable {
        let version: Int
        let base: String
        let fingerprints: Bool
        let producer: String
        let known: KnownFiles
    }

    private func cacheProducer() -> String {
        let executable: URL?
        switch buildMode { case .inProcess: executable = Bundle.main.executableURL; case let .subprocess(cli, _): executable = cli }
        guard let executable, let values = try? executable.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return "unknown-v1" }
        return "\(executable.path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }

    private func restoreCache() {
        guard let cacheDirectory else { return }
        do {
            let data = try Data(contentsOf: cacheDirectory.appendingPathComponent("recall-v1.stream"), options: .mappedIfSafe)
            guard let newline = data.firstIndex(of: 10) else { return }
            let header = try JSONDecoder().decode(CacheHeader.self, from: data.prefix(upTo: newline))
            guard header.version == 1, header.base == StoragePaths.baseDirectory().path,
                  header.fingerprints == includeFingerprints, header.producer == cacheProducer(),
                  header.known.hasValidStorage else { return }
            var stream = BuildStream(), builder: RecallLibrary.Builder?, received = 0, expected = 0
            try stream.feed(data.suffix(from: newline + 1), onHeader: { value in
                guard value.count >= 0, value.count <= header.known.count,
                      value.rawBytes >= 0, value.foldedBytes >= 0,
                      value.rawBytes <= data.count, value.foldedBytes <= data.count else { throw RecallBuildError.invalidRecord }
                expected = value.count
                builder = RecallLibrary.Builder(rawCapacity: value.rawBytes, foldedCapacity: value.foldedBytes)
            }, onRecord: { item, payload in
                guard item.position == received, let layout = item.note else { throw RecallBuildError.invalidRecord }
                builder!.append(layout, payload: payload); received += 1
            })
            guard stream.isComplete, received == expected, let built = builder?.build() else { return }
            for i in 0..<header.known.count {
                let slot = header.known.slots[i]
                guard slot == -1 || (slot >= 0 && slot < built.count && built[slot].filePath == header.known.path(i)) else { return }
            }
            known = header.known; library = built; restoredFromDisk = true
        } catch { /* Rebuild from canonical files; a cache never authorizes evidence. */ }
    }

    private func saveCache() {
        guard let cacheDirectory else { return }
        // Avoid rewriting a large base snapshot on every dictation. A small
        // changed tail is rebuilt canonically until periodic/large compaction.
        let target = cacheDirectory.appendingPathComponent("recall-v1.stream")
        if restoredFromDisk, rebuiltNoteCount < max(64, library.count / 20),
           let modified = try? target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < 180 { return }
        do {
            let header = CacheHeader(version: 1, base: StoragePaths.baseDirectory().path,
                fingerprints: includeFingerprints, producer: cacheProducer(), known: known)
            var data = try JSONEncoder().encode(header); data.append(10)
            data.append(try JSONEncoder().encode(BuildHeader(count: library.count, rawBytes: library.raw.count, foldedBytes: library.folded.count))); data.append(10)
            for i in 0..<library.count {
                let e = library.entries[i]
                let layout = RecallLibrary.Layout(date: e.date, updated: e.updated, fingerprintSnapshot: e.fingerprintSnapshot,
                    kind: e.kind, duration: e.duration, speech: e.speech, chars: e.chars, device: e.device,
                    id: e.id.count, path: e.path.count, title: e.title?.count, summary: e.summary?.count,
                    text: e.text.count, attachments: e.attachments.map(\.count), foldedID: e.foldedID.count,
                    foldedTitle: e.foldedTitle.count, foldedSummary: e.foldedSummary.count, foldedBody: e.foldedBody.count)
                data.append(try JSONEncoder().encode(BuildRecord(position: i, note: layout))); data.append(10)
                data.append(contentsOf: library.raw[e.id.lowerBound..<(e.id.lowerBound + library.rawByteCount(of: i))])
                data.append(contentsOf: library.folded[e.foldedID.lowerBound..<(e.foldedID.lowerBound + library.foldedByteCount(of: i))])
            }
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDirectory.path)
            let file = cacheDirectory.appendingPathComponent("recall-v1.stream")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Optional performance cache; authoritative data stays untouched. */ }
    }

    // MARK: - Building

    /// One record of the child's output: this as a JSON line, then the
    /// note's `payloadBytes` of text (see `RecallLibrary.Layout`).
    struct BuildRecord: Codable {
        /// Index of the file in the request: the parent keeps the URL it
        /// already has instead of allocating one per record mid-stream.
        let position: Int
        /// nil: the note was canceled, and no payload follows.
        let note: RecallLibrary.Layout?

        var payloadBytes: Int { note?.payloadBytes ?? 0 }

        static func encode(position: Int, note: RecallNote?) -> (data: Data, rawBytes: Int, foldedBytes: Int) {
            let encoded = note.map(RecallLibrary.Layout.encode)
            var data = (try? JSONEncoder().encode(BuildRecord(position: position, note: encoded?.layout))) ?? Data()
            data.append(0x0A)
            if let encoded { data.append(encoded.payload) }
            return (data, encoded?.layout.rawBytes ?? 0, encoded?.layout.foldedBytes ?? 0)
        }
    }

    enum RecallBuildError: Error {
        case unknownPosition(Int)
        case invalidRecord
        case truncated
    }

    /// Cuts the child's output, arriving in arbitrary chunks, back into the
    /// header and the records. Text is handed out as raw bytes, never as
    /// `String`s: decoding every note's text into strings left ~30 MB of
    /// fragmented heap behind in the long-running server.
    struct BuildStream {
        private var buffer = Data()
        private var record: BuildRecord?
        private var sawHeader = false
        private let decoder = JSONDecoder()

        /// Every record delivered and nothing left over.
        var isComplete: Bool { sawHeader && record == nil && buffer.isEmpty }

        mutating func feed(
            _ chunk: Data,
            onHeader: (BuildHeader) throws -> Void,
            onRecord: (BuildRecord, UnsafeRawBufferPointer) throws -> Void
        ) throws {
            buffer.append(chunk)
            var cursor = buffer.startIndex
            defer { buffer.removeSubrange(buffer.startIndex..<cursor) }
            while true {
                if let pending = record {
                    let end = cursor + pending.payloadBytes
                    guard end <= buffer.endIndex else { return }
                    try buffer[cursor..<end].withUnsafeBytes { try onRecord(pending, $0) }
                    cursor = end
                    record = nil
                    continue
                }
                // Lines are split on 0x0A only: `bytes.lines` would also break
                // on U+2028, which JSONEncoder leaves unescaped.
                guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else { return }
                let line = buffer[cursor..<newline]
                cursor = newline + 1
                if sawHeader {
                    let next = try decoder.decode(BuildRecord.self, from: line)
                    guard next.note?.isValid ?? true else { throw RecallBuildError.invalidRecord }
                    record = next
                } else {
                    try onHeader(decoder.decode(BuildHeader.self, from: line))
                    sawHeader = true
                }
            }
        }
    }

    struct BuildHeader: Codable {
        let count: Int
        let rawBytes: Int
        let foldedBytes: Int
    }

    /// Build only the explicitly requested files, retaining ordinary note and
    /// attachment semantics. Does not discover or build other library notes.
    public static func loadFiles(_ files: [URL], includeFingerprints: Bool = false) async -> RecallLibrary {
        let notes = await build(files, includeFingerprints: includeFingerprints) { _, _, note in note }
        return RecallLibrary(notes.compactMap { $0 })
    }

    /// Builds every file and hands each result to `finish` on the same worker.
    /// Repositories and their parsed sidecar batches live only for this build.
    static func build<T: Sendable>(
        _ files: [URL],
        includeFingerprints: Bool = false,
        finish: @escaping @Sendable (_ position: Int, URL, RecallNote?) -> T
    ) async -> [T] {
        guard !files.isEmpty else { return [] }
        let index = RecordingsDirectoryIndex(
            directories: Array(Set(files.map { $0.deletingLastPathComponent() })))
        let workers = min(buildWorkers, files.count)
        return await withTaskGroup(of: [T].self) { group in
            for worker in 0..<workers {
                let slice = Array(stride(from: worker, to: files.count, by: workers))
                group.addTask {
                    let metaRepo = MetadataRepository()
                    let transcriptRepo = TranscriptRepository()
                    var out: [T] = []
                    out.reserveCapacity(slice.count)
                    for (i, position) in slice.enumerated() {
                        let file = files[position]
                        let note = await NoteBuilder.build(
                            file: file,
                            index: i,
                            metaRepo: metaRepo,
                            transcriptRepo: transcriptRepo,
                            directoryIndex: index
                        )
                        guard !note.isCanceled else {
                            out.append(finish(position, file, nil))
                            continue
                        }
                        // NoteBuilder keeps the parsed sidecar to itself; one more
                        // read here, in the build child, costs less than widening `Note`.
                        let before = includeFingerprints ? NoteFingerprintSnapshot.stamps(for: file) : nil
                        let sidecar = await metaRepo.metadata(for: file)
                        let snapshot = includeFingerprints
                            ? NoteFingerprintSnapshot.capture(file: file, sidecar: sidecar, before: before) : nil
                        out.append(finish(position, file, RecallNote(
                            note: note, sidecar: sidecar, updated: Self.lastChange(of: file)).withFingerprintSnapshot(snapshot)))
                    }
                    return out
                }
            }
            var all: [T] = []
            all.reserveCapacity(files.count)
            for await part in group { all.append(contentsOf: part) }
            return all
        }
    }

    /// The later of the note file's and its sidecar's mtimes — the same two
    /// stamps a reload compares to decide a note must be rebuilt, so a kept
    /// note's `updated` is still right.
    public static func lastChange(of file: URL) -> Date? {
        let sidecar = FileStore.metadataURL(forRecordingURL: file)
        return [file, sidecar].compactMap { url -> Date? in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            let m = info.st_mtimespec
            return Date(timeIntervalSince1970: TimeInterval(m.tv_sec) + TimeInterval(m.tv_nsec) / 1e9)
        }.max()
    }

    /// The child side: file paths in, one record per path out — a header
    /// with exact byte totals first, so the parent sizes its buffers once.
    /// Folding and encoding happen here, on the build workers; the parent
    /// only copies bytes.
    public static func serveBuild(
        includeFingerprints: Bool = false,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) async {
        let paths = String(decoding: input.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        let built = await build(paths, includeFingerprints: includeFingerprints
            || ProcessInfo.processInfo.environment["WIMM_RECALL_FINGERPRINTS"] == "1") { position, _, note in
            BuildRecord.encode(position: position, note: note)
        }
        let header = BuildHeader(
            count: built.count,
            rawBytes: built.reduce(0) { $0 + $1.rawBytes },
            foldedBytes: built.reduce(0) { $0 + $1.foldedBytes }
        )
        var chunk = (try? JSONEncoder().encode(header)) ?? Data()
        chunk.append(0x0A)
        for item in built {
            chunk.append(item.data)
            if chunk.count > 1 << 20 {
                output.write(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        output.write(chunk)
    }

    /// The parent side. Returns nil when the child did not deliver every
    /// record, and the caller rebuilds in process.
    private func buildInChild(
        _ stale: [URL],
        executable: URL,
        arguments: [String],
        start: (Int, Int) -> RecallLibrary.Builder,
        record: (_ position: Int, _ slot: Int?) -> Void
    ) async -> RecallLibrary.Builder? {
        #if !os(macOS)
        // iOS has no Process; the caller rebuilds in process on nil.
        return nil
        #else
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if includeFingerprints {
            var environment = ProcessInfo.processInfo.environment
            environment["WIMM_RECALL_FINGERPRINTS"] = "1"
            process.environment = environment
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        do { try process.run() } catch { return nil }
        let request = Data(stale.map(\.path).joined(separator: "\n").utf8)
        let writer = stdin.fileHandleForWriting
        Thread.detachNewThread {
            writer.write(request)
            try? writer.close()
        }

        var builder: RecallLibrary.Builder?
        var expected = -1
        var received = 0
        var stream = BuildStream()
        // Read in large chunks: iterating `FileHandle.bytes` from this actor
        // paid a task switch and an actor lock per byte — ~5 s of a ~7 s
        // first load.
        let reader = stdout.fileHandleForReading
        do {
            while let chunk = try await Self.readChunk(reader) {
                try stream.feed(chunk, onHeader: { header in
                    expected = header.count
                    builder = start(header.rawBytes, header.foldedBytes)
                }, onRecord: { item, payload in
                    guard stale.indices.contains(item.position) else {
                        throw RecallBuildError.unknownPosition(item.position)
                    }
                    var slot: Int?
                    if let layout = item.note {
                        slot = builder!.count
                        builder!.append(layout, payload: payload)
                    }
                    record(item.position, slot)
                    received += 1
                })
            }
            guard stream.isComplete else { throw RecallBuildError.truncated }
        } catch {
            log("[MCP] build child output unreadable: \(error)")
            // Unread output would block the child on a full pipe forever.
            process.terminate()
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, received == expected, received == stale.count else {
            log("[MCP] build child failed (status \(process.terminationStatus), \(received)/\(stale.count)); building in process")
            return nil
        }
        return builder
        #endif
    }

    private static let readQueue = DispatchQueue(label: "app.wimm.mcp.build-reader")

    /// The next block of the child's output, nil at its end. The blocking
    /// read runs off the cooperative pool, and the child waits on a full pipe
    /// until the parent asks again, so its output is never buffered whole.
    private static func readChunk(_ handle: FileHandle) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async {
                continuation.resume(with: Result {
                    let data = try handle.read(upToCount: 1 << 20)
                    return data?.isEmpty == false ? data : nil
                })
            }
        }
    }

    /// The directories `FileRepository` lists notes from.
    private static func libraryDirectories() -> [URL] {
        [FileStore.recordingsDirectory(), FileStore.legacyRecordingsDirectory()]
    }

    /// Every visible entry of the directories with its mtime, keyed by
    /// `path` as `FileRepository` builds it (directory path + name).
    /// `readdir` + `fstatat` instead of `contentsOfDirectory`: that made a
    /// `URL` with a resource cache per entry — ~25k of them on every check,
    /// whose freed remains kept the server's heap fragmented.
    static func modificationDates(in directories: [URL]) -> [String: Date] {
        var out: [String: Date] = [:]
        for directory in directories {
            let base = directory.path
            guard let dir = opendir(base) else { continue }
            defer { closedir(dir) }
            let fd = dirfd(dir)
            while let entry = readdir(dir) {
                let name = withUnsafePointer(to: entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(cString: $0)
                    }
                }
                if name.hasPrefix(".") { continue }
                var info = stat()
                guard fstatat(fd, name, &info, 0) == 0 else { continue }
                let mtime = info.st_mtimespec
                out[base + "/" + name] = Date(
                    timeIntervalSince1970: TimeInterval(mtime.tv_sec) + TimeInterval(mtime.tv_nsec) / 1e9)
            }
        }
        return out
    }
}

private extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
