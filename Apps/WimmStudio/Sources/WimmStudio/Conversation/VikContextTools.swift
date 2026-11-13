import Foundation
import WimmDomain
import WimmInfrastructure
import WimmSecretary

/// One exchange's immutable document and lazily read note evidence. No secretary
/// run, marks, receipts or sidecar writes. IDs cannot drift if the document reloads.
actor VikContextTools {
    typealias Files = @Sendable () async -> [URL]
    typealias Load = @Sendable ([URL]) async -> RecallLibrary
    private let document: String
    private let source: URL
    private let asOf: Date
    private let isAllowed: @Sendable () async -> Bool
    private let files: Files
    private let load: Load
    private var available: RecallLibrary?
    private var readTexts: [String: String] = [:]
    private var evidence: [String] = []

    init(document: String, source: URL, asOf: Date = Date(),
         isAllowed: @escaping @Sendable () async -> Bool,
         files: @escaping Files = { await FileRepository().recordings() },
         load: @escaping Load = { await LibraryRecallSource.loadFiles($0) }) {
        self.document = document; self.source = source; self.asOf = asOf
        self.isAllowed = isAllowed; self.files = files; self.load = load
    }

    nonisolated var tools: [GeminiChatStream.Tool] {
        [
            tool("previous_note", "Read the note immediately before the current recording, including all labeled text variants. Does not skip silent notes. Page with offset (characters).", properties: offset),
            tool("notes_last_hour", "List notes captured in the hour before this question, newest first, excluding the current note. Returns IDs; read their evidence with read_note. Page with offset (notes).", properties: offset),
            tool("read_note", "Read a note returned by notes_last_hour or previous_note. All text variants have provenance labels; live/local/cloud can disagree. Page with offset (characters).", properties: "\"id\":{\"type\":\"string\"}," + offset, required: ["id"]),
            tool("document_outline", "Read the personal document's headings and block IDs. Page with offset (headings).", properties: offset),
            tool("document_section", "Read a section and its subsections using an exact heading ID from document_outline. Page with offset (blocks) and nextOffset.", properties: "\"id\":{\"type\":\"string\"}," + offset, required: ["id"]),
            tool("document_blocks", "Read exact document block IDs returned by section/outline. No guessing IDs.", properties: "\"ids\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"maxItems\":20}", required: ["ids"])
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
        if PrivateMode.isEnabled { throw PseudonymizationError.cloudRequestRefused("Vik context") }
        guard await isAllowed() else { throw CancellationError() }
    }

    func transcript() -> String { evidence.joined(separator: "\n\n") }

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
            let headings = SecretaryDocumentReader.outline(document: document)
            let page = Array(headings.dropFirst(offset).prefix(100))
            result = try encode(Page(items: page, total: headings.count,
                                     nextOffset: offset + page.count < headings.count ? offset + page.count : nil))
        case "document_section":
            guard let id = args["id"] as? String else { return "error: id required" }
            result = try encode(SecretaryDocumentReader.section(document: document, query: id, offset: offset, byteLimit: 16_000))
        case "document_blocks":
            guard let ids = args["ids"] as? [String], !ids.isEmpty, ids.count <= 20 else { return "error: supply 1–20 block IDs" }
            let blocks = SecretaryDocumentReader.blocks(document: document, ids: ids)
            guard blocks.reduce(0, { $0 + $1.text.utf8.count }) <= 64_000 else {
                return "error: requested blocks exceed 64000 bytes; request fewer IDs"
            }
            result = try encode(BlockRead(blocks: blocks, missing: ids.filter { id in !blocks.contains { $0.id == id } }))
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
                let note: RecallNote?
                if name == "previous_note" { note = NoteRecall.recent(library, until: sourceDate, limit: 1).first }
                else if let id = args["id"] as? String { note = NoteRecall.find(library, id: id) }
                else { return "error: id required" }
                guard let note else { return "not_found: no matching prior note" }
                let text: String
                if let cached = readTexts[note.id] { text = cached }
                else {
                    let reader = MCPRecallServer(library: { library })
                    text = reader.readNote(note, full: true, format: .secretaryPacket).text
                    readTexts[note.id] = text
                }
                let page = String(text.dropFirst(offset).prefix(12_000))
                result = try encode(NotePage(id: note.id, date: note.date, text: page, totalCharacters: text.count,
                                             nextOffset: offset + page.count < text.count ? offset + page.count : nil))
            }
        default: return "error: unavailable read tool"
        }
        try await checkAccess()
        guard result.utf8.count <= 64_000 else { return "error: read exceeds 64000 bytes; request individual blocks or a smaller page" }
        evidence.append("### \(name) \(arguments)\n\n\(result)")
        log("[VikContext] tool=\(name) result_bytes=\(result.utf8.count)")
        return result
    }

    private var sourceDate: Date { FileStore.recordingDateFromFileName(source) ?? asOf }

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

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private struct Page<Item: Encodable>: Encodable { let items: [Item]; let total: Int; let nextOffset: Int? }
    private struct Listing: Encodable { let id: String; let date: Date; let kind: String; let speech: String?; let preview: String }
    private struct NotePage: Encodable { let id: String; let date: Date; let text: String; let totalCharacters: Int; let nextOffset: Int? }
    private struct BlockRead: Encodable { let blocks: [SecretaryDocumentReader.Block]; let missing: [String] }
}
