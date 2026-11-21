import Foundation
import WimmDomain
import WimmInfrastructure
import WimmSecretary

/// One exchange's immutable document and lazily read note evidence. No secretary
/// run, marks, receipts or sidecar writes. IDs cannot drift if the document reloads.
///
/// Tools follow the just-in-time pattern: the model gets small listings and
/// search hits with IDs, then reads the few items it needs in full. Every
/// result is data for the model, never an instruction, and every error says
/// what to do next instead of ending the exchange.
actor VikContextTools {
    typealias Files = @Sendable () async -> [URL]
    typealias Load = @Sendable ([URL]) async -> RecallLibrary
    /// The whole library for search; nil when it cannot be loaded here.
    typealias Library = @Sendable () async -> RecallLibrary?
    typealias Replies = @Sendable (Date) async -> [VikReplyLog.Entry]
    private let document: String
    private let source: URL
    private let asOf: Date
    private let isAllowed: @Sendable () async -> Bool
    private let files: Files
    private let load: Load
    private let library: Library
    private let replies: Replies
    private let reviewQueue: @Sendable () -> String?
    private var available: RecallLibrary?
    private var whole: RecallLibrary?
    private var snapshot: SecretaryDocumentReader.Snapshot?
    private var readTexts: [String: String] = [:]
    private var evidence: [String] = []

    init(document: String, source: URL, asOf: Date = Date(),
         isAllowed: @escaping @Sendable () async -> Bool,
         files: @escaping Files = { await FileRepository().recordings() },
         load: @escaping Load = { await LibraryRecallSource.loadFiles($0) },
         library: @escaping Library = { nil },
         replies: @escaping Replies = { VikReplyLog.recent(before: $0) },
         reviewQueue: @escaping @Sendable () -> String? = { nil }) {
        self.document = document; self.source = source; self.asOf = asOf
        self.isAllowed = isAllowed; self.files = files; self.load = load
        self.library = library; self.replies = replies; self.reviewQueue = reviewQueue
    }

    nonisolated var tools: [GeminiChatStream.Tool] {
        [
            tool("previous_note", "Read the note recorded immediately before the current one, with all labeled text variants. Use first when the user says «предыдущая запись», «до этого», «как я сказал». Does not skip silent notes. Page with offset (characters).", properties: offset),
            tool("notes_last_hour", "List notes captured in the hour before this question, newest first, excluding the current note. Previews only: read the ones you need with read_note. Page with offset (notes).", properties: offset),
            tool("search_notes", "Search the user's whole note library (voice, text, imports) by words, optionally within dates; or list a period's notes by leaving query empty («что я записал вчера»). Use rare words: names, places, amounts, not whole questions; every word must occur in a note. Russian word endings are matched loosely. Returns IDs, dates and snippets; read evidence with read_note. Page with offset (hits).", properties: "\"query\":{\"type\":\"string\"},\"since\":{\"type\":\"string\",\"description\":\"YYYY-MM-DD or ISO date-time, local time; inclusive\"},\"until\":{\"type\":\"string\",\"description\":\"YYYY-MM-DD (whole day included) or ISO date-time\"}," + offset),
            tool("read_note", "Read one note in full by an ID from notes_last_hour, search_notes or previous_note. All text variants have provenance labels; live/local/cloud can disagree. Page with offset (characters).", properties: "\"id\":{\"type\":\"string\"}," + offset, required: ["id"]),
            tool("document_outline", "Read the personal document's headings and block IDs. Page with offset (headings).", properties: offset),
            tool("document_find", "Search the personal document for one or several topics in one call (names, places, amounts, literal phrases). Returns matching blocks with IDs and the heading path above each. Prefer this over guessing a section from the outline.", properties: "\"queries\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"minItems\":1,\"maxItems\":6}", required: ["queries"]),
            tool("document_section", "Read a section and its subsections using an exact heading ID from document_outline. Page with offset (blocks) and nextOffset.", properties: "\"id\":{\"type\":\"string\"}," + offset, required: ["id"]),
            tool("document_blocks", "Read exact document block IDs returned by section/outline/find. No guessing IDs.", properties: "\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"maxItems\":20}", required: ["ids"]),
            tool("my_recent_replies", "Read your own last exchanges with the user (their question and your answer) from the two hours before this one, newest first. Use only when the user follows up on something you said («а подробнее», «повтори», «почему ты так сказала»); otherwise each question stands alone.", properties: "\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":5}"),
            tool("secretary_questions", "List the open questions the secretary is waiting for the user to answer (numbers Q…, text, answer options). Use when the user asks what the secretary asked or what is waiting for an answer. Page with offset (questions).", properties: offset),
        ]
    }

    private nonisolated var offset: String { "\"offset\":{\"type\":\"integer\",\"minimum\":0}" }

    private nonisolated func tool(_ name: String, _ description: String, properties: String,
                                  required: [String] = []) -> GeminiChatStream.Tool {
        let requiredJSON = required.map { "\"\($0)\"" }.joined(separator: ",")
        return .init(name: name, description: description,
                     parametersJSON: "{\"type\":\"object\",\"properties\":{\(properties)},\"required\":[\(requiredJSON)]}") { args in
            try await self.read(name, arguments: args)
        }
    }

    private func checkAccess() async throws {
        try Task.checkCancellation()
        if PrivateMode.isEnabled { throw PrivateModeError.cloudRequestRefused("Vik context") }
        guard await isAllowed() else { throw CancellationError() }
    }

    func transcript() -> String { evidence.joined(separator: "\n\n") }

    /// First pages of the two reads nearly every question starts with, sent with
    /// the first request so the model does not spend a round asking for each.
    /// The two reads run side by side: the note list waits on the disk while the outline parses.
    func preloaded() async throws -> String {
        async let listing = read("notes_last_hour", arguments: "{}")
        let outline = try await read("document_outline", arguments: "{}")
        let recent = try await listing
        return "document_outline:\n\(outline)\n\nnotes_last_hour:\n\(recent)"
    }

    func read(_ name: String, arguments: String) async throws -> String {
        try await checkAccess()
        guard let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] else {
            return "error: arguments must be a JSON object"
        }
        let offset = args["offset"] as? Int ?? 0
        guard offset >= 0 else { return "error: offset must be nonnegative" }
        let result: String
        switch name {
        case "document_outline":
            let headings = documentSnapshot().outline()
            let page = Array(headings.dropFirst(offset).prefix(100))
            result = try encode(Page(items: page, total: headings.count,
                                     nextOffset: offset + page.count < headings.count ? offset + page.count : nil))
        case "document_section":
            guard let id = args["id"] as? String else { return "error: id required (a heading ID from document_outline)" }
            result = try encode(documentSnapshot().section(query: id, offset: offset, byteLimit: 16_000))
        case "document_blocks":
            guard let ids = args["ids"] as? [String], !ids.isEmpty, ids.count <= 20 else { return "error: supply 1–20 block IDs" }
            let blocks = documentSnapshot().blocks(ids: ids)
            guard blocks.reduce(0, { $0 + $1.text.utf8.count }) <= 64_000 else {
                return "error: requested blocks exceed 64000 bytes; request fewer IDs"
            }
            result = try encode(BlockRead(blocks: blocks, missing: ids.filter { id in !blocks.contains { $0.id == id } }))
        case "document_find":
            let queries = (args["queries"] as? [String] ?? (args["query"] as? String).map { [$0] } ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !queries.isEmpty, queries.count <= 6 else { return "error: supply 1–6 non-empty queries" }
            guard !document.isEmpty else { return "not_found: no personal document is open" }
            result = try encode(documentSnapshot().find(queries: queries, byteLimit: 16_000))
        case "search_notes":
            guard let library = try await wholeLibrary() else {
                return "error: library search is unavailable right now; use notes_last_hour or previous_note"
            }
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let since: Date?, until: Date?
            do {
                since = try Self.date(args["since"], endOfDay: false)
                until = try Self.date(args["until"], endOfDay: true)
            } catch { return error.localizedDescription }
            guard !query.isEmpty || since != nil || until != nil else {
                return "error: give query words, or since/until to list a period"
            }
            let end = min(until ?? sourceDate, sourceDate)
            let exclude = source.standardizedFileURL.path
            let found = NoteRecall.searchPage(library, query: query, since: since, until: end,
                                              offset: 0, limit: offset + 11)
            let hits = found.hits.filter { URL(fileURLWithPath: $0.note.filePath).standardizedFileURL.path != exclude }
            let total = found.total - (found.hits.count - hits.count)
            let page = Array(hits.dropFirst(offset).prefix(10))
            let items = page.map { hit in
                Listing(id: hit.note.id, date: hit.note.date, kind: hit.note.kind, speech: hit.note.speech,
                        preview: String((query.isEmpty ? hit.note.text : hit.snippet).prefix(240)))
            }
            guard !items.isEmpty || offset > 0 else {
                return "not_found: no note matches \(query.isEmpty ? "this period" : "all of these words"); try fewer or other words, or a wider period"
            }
            result = try encode(Page(items: items, total: total,
                                     nextOffset: offset + items.count < total ? offset + items.count : nil))
        case "previous_note", "notes_last_hour", "read_note":
            let library = try await notes()
            if name == "notes_last_hour" {
                let page = NoteRecall.recentPage(library, since: asOf.addingTimeInterval(-3600),
                                                 until: sourceDate, offset: offset, limit: 20)
                // A listing is explicitly a preview; read_note supplies complete, paged evidence.
                let items = page.notes.map { Listing(id: $0.id, date: $0.date, kind: $0.kind,
                                                     speech: $0.speech, preview: String($0.text.prefix(240))) }
                result = try encode(Page(items: items, total: page.total,
                                         nextOffset: offset + items.count < page.total ? offset + items.count : nil))
            } else {
                var found: (note: RecallNote, from: RecallLibrary)?
                if name == "previous_note" {
                    found = NoteRecall.recent(library, until: sourceDate, limit: 1).first.map { ($0, library) }
                } else if let id = args["id"] as? String {
                    if let note = NoteRecall.find(library, id: id) { found = (note, library) }
                    else if let whole = try await wholeLibrary(), let note = NoteRecall.find(whole, reference: id),
                            URL(fileURLWithPath: note.filePath).standardizedFileURL != source.standardizedFileURL {
                        found = (note, whole)
                    }
                } else { return "error: id required" }
                guard let found else {
                    return "not_found: no matching prior note; use an ID exactly as notes_last_hour or search_notes returned it"
                }
                let note = found.note, notes = found.from
                let text: String
                if let cached = readTexts[note.id] { text = cached }
                else {
                    let reader = MCPRecallServer(library: { notes })
                    text = reader.readNote(note, full: true, format: .secretaryPacket).text
                    readTexts[note.id] = text
                }
                let page = String(text.dropFirst(offset).prefix(12_000))
                result = try encode(NotePage(id: note.id, date: note.date, text: page, totalCharacters: text.count,
                                             nextOffset: offset + page.count < text.count ? offset + page.count : nil))
            }
        case "my_recent_replies":
            let limit = min(5, max(1, args["limit"] as? Int ?? 3))
            let entries = await replies(asOf).prefix(limit)
            guard !entries.isEmpty else { return "not_found: no exchange with you in the two hours before this question" }
            result = try encode(Array(entries))
        case "secretary_questions":
            guard let queue = reviewQueue() else { return "not_found: the secretary's question queue is not available" }
            let questions = SecretaryReviewQueue.openQuestions(in: queue)
            let page = Array(questions.dropFirst(offset).prefix(10)).map {
                Question(number: $0.number, text: String($0.text.prefix(600)),
                         options: $0.options?.map { "\($0.key)) \($0.label)" }, recommend: $0.recommend)
            }
            result = try encode(Page(items: page, total: questions.count,
                                     nextOffset: offset + page.count < questions.count ? offset + page.count : nil))
        default: return "error: unavailable read tool"
        }
        try await checkAccess()
        guard result.utf8.count <= 64_000 else { return "error: read exceeds 64000 bytes; request individual blocks or a smaller page" }
        evidence.append("### \(name) \(arguments)\n\n\(result)")
        log("[VikContext] tool=\(name) result_bytes=\(result.utf8.count)")
        return result
    }

    private var sourceDate: Date { FileStore.recordingDateFromFileName(source) ?? asOf }

    /// One parse of the exchange's frozen document serves every document tool.
    private func documentSnapshot() -> SecretaryDocumentReader.Snapshot {
        if let snapshot { return snapshot }
        let built = SecretaryDocumentReader.Snapshot(document: document)
        snapshot = built
        return built
    }

    private func wholeLibrary() async throws -> RecallLibrary? {
        if let whole { return whole }
        let loaded = await library()
        try await checkAccess()
        whole = loaded
        return loaded
    }

    private func notes() async throws -> RecallLibrary {
        if let available { return available }
        let candidates = await files()
        try await checkAccess()
        let dated = candidates.filter { $0.standardizedFileURL != source.standardizedFileURL }.compactMap { url -> (URL, Date)? in
            guard let date = FileStore.recordingDateFromFileName(url) ?? (try? FileStore.fileCreationDate(url)), date < sourceDate else { return nil }
            return (url, date)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        // Build only the hour's notes and the immediately preceding note, even
        // when that note is older. Reuse the secretary/MCP note builder.
        var selected = dated.filter { $0.1 >= asOf.addingTimeInterval(-3600) }.map(\.0)
        if let previous = dated.first?.0, !selected.contains(previous) { selected.append(previous) }
        let library = await load(selected)
        try await checkAccess()
        available = library
        return library
    }

    /// `YYYY-MM-DD` (local day; `endOfDay` takes the whole day) or an ISO date-time.
    static func date(_ value: Any?, endOfDay: Bool, calendar: Calendar = .current) throws -> Date? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let day = DateFormatter()
        day.calendar = calendar; day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        if let start = day.date(from: text) {
            return endOfDay ? calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-0.001) : start
        }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let iso = ISO8601DateFormatter(); iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            day.dateFormat = format
            if let date = day.date(from: text) { return date }
        }
        throw DateError(text: text)
    }

    struct DateError: LocalizedError {
        let text: String
        var errorDescription: String? { "error: cannot read date \(text); use YYYY-MM-DD" }
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private struct Page<Item: Encodable>: Encodable { let items: [Item]; let total: Int; let nextOffset: Int? }
    private struct Listing: Encodable { let id: String; let date: Date; let kind: String; let speech: String?; let preview: String }
    private struct NotePage: Encodable { let id: String; let date: Date; let text: String; let totalCharacters: Int; let nextOffset: Int? }
    private struct BlockRead: Encodable { let blocks: [SecretaryDocumentReader.Block]; let missing: [String] }
    private struct Question: Encodable { let number: Int; let text: String; let options: [String]?; let recommend: String? }
}
