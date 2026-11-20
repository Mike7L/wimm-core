import CryptoKit
import Foundation
import WimmInfrastructure

/// The personal document as MCP read tools. The server process is long-lived, so the
/// document is parsed once per file version and every later call is a lookup: an
/// agent pays neither a process start nor a re-parse per read, and one call can
/// carry several sections or several searches.
///
/// Read-only. No document path argument: the server reads the one configured
/// document, never an arbitrary file. Private mode is refused by the server before
/// a tool is reached.
public enum SecretaryDocumentTools {
    public static let instructions = """
        The user's personal Markdown document (their knowledge base) is readable with \
        document_outline (headings with block IDs), document_section (one or several \
        sections in one call), document_find (one or several searches in one call) and \
        document_blocks. Ask for everything you need in one call rather than one call \
        per section. Block IDs belong to one document version: pass the returned \
        `version` back to detect a document that changed in between. Search with the \
        rare words of the topic (names, places, amounts) rather than whole questions; a \
        found block carries `path`, the headings above it, which give the year and the \
        topic its first line leaves out. Answer from block text: quote it and keep its \
        source links ([S…]). A summary chapter is true as of the date in its heading, and \
        a chapter that calls itself a model's opinion is not evidence.
        """

    static let maxBytes = 120_000

    public static func mcpTools(document: @escaping @Sendable () -> URL?) -> [MCPRecallServer.ExtraTool] {
        let cache = Cache(document: document)
        let version: [String: Any] = ["type": "string", "description": "`version` from an earlier result; the call fails if the document changed since"]
        let limit: [String: Any] = ["type": "integer", "description": "Maximum UTF-8 bytes of block text in this result (default 48000, max \(maxBytes))"]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = [],
                  _ run: @escaping @Sendable (Loaded, [String: Any]) throws -> any Encodable) -> MCPRecallServer.ExtraTool {
            var all = properties
            all["version"] = version
            return .init(name: name, description: description,
                         inputSchema: ["type": "object", "properties": all, "required": required]) { data in
                let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                let loaded = try await cache.load()
                if let expected = arguments["version"] as? String, expected != loaded.version {
                    throw MCPRecallServer.ToolError("The document changed (version \(loaded.version), not \(expected)): block IDs moved. Read document_outline again.")
                }
                return try encode(loaded.version, try run(loaded, arguments))
            }
        }
        return [
            tool("document_outline",
                 "Headings of the user's personal document with block IDs, depth and subtree size in bytes. Start here. max_depth 2 gives a short map of a large document.",
                 ["max_depth": ["type": "integer", "minimum": 1, "maximum": 6],
                  "offset": ["type": "integer", "minimum": 0, "description": "First heading of the page (from next_offset)"]]) { loaded, arguments in
                let depth = int(arguments["max_depth"]) ?? 6, offset = max(0, int(arguments["offset"]) ?? 0)
                let headings = loaded.snapshot.outline().filter { $0.depth <= depth }
                let page = Array(headings.dropFirst(offset).prefix(1_000))
                return Outline(headings: page, total: headings.count,
                               nextOffset: offset + page.count < headings.count ? offset + page.count : nil)
            },
            tool("document_section",
                 "Read whole sections (with subsections) of the personal document: up to 8 heading block IDs (b12) or exact heading titles in one call. Sections share limit_bytes in the order given; a section that did not fit entirely returns status partial with next_offset, the ones not started are listed in not_read. offset continues one section.",
                 ["sections": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 8],
                  "offset": ["type": "integer", "minimum": 0, "description": "First block of the page; only with a single section"],
                  "limit_bytes": limit], required: ["sections"]) { loaded, arguments in
                let queries = strings(arguments["sections"])
                guard (1...8).contains(queries.count) else { throw MCPRecallServer.ToolError("sections must list 1 to 8 heading IDs or titles") }
                let offset = max(0, int(arguments["offset"]) ?? 0)
                guard offset == 0 || queries.count == 1 else { throw MCPRecallServer.ToolError("offset continues one section: pass a single section with it") }
                var remaining = bytes(arguments["limit_bytes"])
                var reads: [SectionResult] = [], notRead: [String] = []
                for query in queries {
                    guard remaining > 0 else { notRead.append(query); continue }
                    let read = loaded.snapshot.section(query: query, offset: offset, byteLimit: remaining)
                    remaining -= read.blocks.reduce(0) { $0 + $1.text.utf8.count }
                    reads.append(SectionResult(query: query, read: read))
                }
                return Sections(sections: reads, notRead: notRead)
            },
            tool("document_find",
                 "Search the personal document: up to 5 literal phrases or word sets in one call (a `;` inside a query separates alternatives). Picks the best matches first (rare words weigh more) and returns them in document order, each with its heading and `path` (all headings above it), under one shared limit_bytes, round-robin across queries, and per query a status (matched / partial / not_found), the block IDs left out for budget and the words that occur nowhere. Lexical only: no match does not prove the topic is absent.",
                 ["queries": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 5],
                  "limit_bytes": limit], required: ["queries"]) { loaded, arguments in
                let queries = strings(arguments["queries"]).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard (1...5).contains(queries.count), queries.allSatisfy({ $0.count <= 200 }) else {
                    throw MCPRecallServer.ToolError("queries must list 1 to 5 non-empty strings of at most 200 characters")
                }
                return loaded.snapshot.find(queries: queries, byteLimit: bytes(arguments["limit_bytes"]))
            },
            tool("document_blocks",
                 "Read exact blocks of the personal document by ID (from an outline, a section or omitted_for_budget), up to 50, each with `path` (the headings above it).",
                 ["ids": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 50]], required: ["ids"]) { loaded, arguments in
                let ids = strings(arguments["ids"])
                guard (1...50).contains(ids.count) else { throw MCPRecallServer.ToolError("ids must list 1 to 50 block IDs") }
                let blocks = loaded.snapshot.blocks(ids: ids)
                let found = Set(blocks.map(\.id))
                return Blocks(blocks: blocks, missing: ids.filter { !found.contains($0) })
            },
        ]
    }

    // MARK: - Results

    struct Outline: Encodable { let headings: [SecretaryDocumentReader.Heading]; let total: Int; let nextOffset: Int? }
    struct SectionResult: Encodable { let query: String; let read: SecretaryDocumentReader.SectionRead }
    struct Sections: Encodable { let sections: [SectionResult]; let notRead: [String] }
    struct Blocks: Encodable { let blocks: [SecretaryDocumentReader.Block]; let missing: [String] }
    private struct Envelope<Result: Encodable>: Encodable { let version: String; let result: Result }

    private static func encode(_ version: String, _ result: any Encodable) throws -> String {
        func open<Result: Encodable>(_ result: Result) throws -> Data {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(Envelope(version: version, result: result))
        }
        return String(decoding: try open(result), as: UTF8.self)
    }

    private static func strings(_ value: Any?) -> [String] {
        let list = (value as? [Any])?.compactMap { $0 as? String } ?? (value as? String).map { [$0] } ?? []
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func bytes(_ value: Any?) -> Int { min(maxBytes, max(1, int(value) ?? 48_000)) }

    // MARK: - Cache

    struct Loaded: Sendable {
        let snapshot: SecretaryDocumentReader.Snapshot
        /// First 12 hex digits of the file's SHA-256.
        let version: String
    }

    /// One parsed document, replaced when the file's path, size or modification
    /// time changes. A check is one `stat`.
    actor Cache {
        private struct Stamp: Equatable { let path: String; let size: Int; let modified: Date }
        private let document: @Sendable () -> URL?
        private var stamp: Stamp?
        private var loaded: Loaded?
        private(set) var parses = 0

        init(document: @escaping @Sendable () -> URL?) { self.document = document }

        func load() throws -> Loaded {
            guard let url = document() else {
                throw MCPRecallServer.ToolError("No personal document is configured: open one in Wimm Studio, or start the server with WIMM_DOCUMENT=/path/to/document.md.")
            }
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes?[.size] as? Int, let modified = attributes?[.modificationDate] as? Date else {
                throw MCPRecallServer.ToolError("The personal document is not readable: \(url.lastPathComponent)")
            }
            let now = Stamp(path: url.path, size: size, modified: modified)
            if now == stamp, let loaded { return loaded }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                throw MCPRecallServer.ToolError("The personal document is not readable UTF-8 text: \(url.lastPathComponent)")
            }
            let digest = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
            let fresh = Loaded(snapshot: SecretaryDocumentReader.Snapshot(document: text), version: digest)
            parses += 1
            stamp = now; loaded = fresh
            return fresh
        }
    }
}
