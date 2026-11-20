import Foundation

/// Read-only access to a personal Markdown document outside any secretary packet:
/// the outline, one section with its subsections, and literal/term search.
///
/// The secretary's addressed reads (`SecretaryPacket.addressedRead`) use the same
/// section matching and ranges, so both agree on what "a section" is. This reader
/// has no packet, budget ledger or bookkeeping: callers (`wimm-cli doc`, the MCP
/// document tools, Studio's question command) only read.
public enum SecretaryDocumentReader {
    public struct Heading: Codable, Sendable, Equatable {
        /// Block ID of the heading ("b12"), stable while the text above it is unchanged.
        public let id: String
        /// The heading line as written, e.g. "## Работа".
        public let title: String
        public let depth: Int
        /// UTF-8 bytes of the heading's whole subtree, citation definitions excluded.
        public let bytes: Int
    }

    public struct Block: Codable, Sendable, Equatable {
        public let id: String
        public let section: String
        public let text: String
        /// Every heading above the block, outermost first ("## Деньги › ### С Владой"), in
        /// search and block reads, where a block arrives without its chapter. A diary entry
        /// that starts "**10 августа.**" names neither the year nor the person; the path does.
        public var path: String? = nil
    }

    public struct SectionRead: Codable, Sendable {
        /// complete, partial (more pages via `nextOffset`), not_found or ambiguous.
        public let status: String
        public let heading: Heading?
        public let blocks: [Block]
        public let totalBlocks: Int
        public let nextOffset: Int?
        /// Candidates when the query is ambiguous or not found by exact match.
        public let matches: [Heading]
    }

    public struct FindRead: Codable, Sendable {
        /// found, partial or not_found (from the secretary's context search).
        public let status: String
        public let blocks: [Block]
        public let omittedForBudget: [String]
        public let unmatchedTerms: [String]
    }

    /// Several searches in one call: one shared byte budget, round-robin across
    /// queries, one report per query.
    public struct MultiFindRead: Codable, Sendable {
        public struct Report: Codable, Sendable {
            public let query: String
            public let status: String
            public let omittedForBudget: [String]
            public let unmatchedTerms: [String]
        }
        public let blocks: [Block]
        public let reports: [Report]
    }

    public static func outline(document: String) -> [Heading] { Snapshot(document: document).outline() }

    /// One section by exact heading block ID or heading title ("Работа" or "## Работа"),
    /// whole blocks from `offset` up to `byteLimit` (at least one block per page).
    public static func section(document: String, query: String, offset: Int = 0, byteLimit: Int = 24_000) -> SectionRead {
        Snapshot(document: document).section(query: query, offset: offset, byteLimit: byteLimit)
    }

    /// The secretary's document search: literal phrases and terms, round-robin across clauses,
    /// a heading and its first body block together. Citation definitions are never returned.
    public static func find(document: String, query: String, byteLimit: Int = 24_000) -> FindRead {
        Snapshot(document: document).find(query: query, byteLimit: byteLimit)
    }

    /// Exact blocks from the same snapshot and ID space used by outline/section.
    /// Citation definitions are not evidence blocks.
    public static func blocks(document: String, ids: [String]) -> [Block] {
        Snapshot(document: document).blocks(ids: ids)
    }

    /// One document version parsed once. A one-shot caller (`wimm-cli doc`) builds it
    /// per call; a long-lived one (the MCP server) keeps it until the file changes,
    /// so a read costs no parsing. Immutable; the search index is built on first `find`.
    public final class Snapshot: @unchecked Sendable {
        private let all: [SecretaryPacket.Block]
        private let parsed: [SecretaryPacket.BlockIndex.Heading?]
        private let definitions: [Bool]
        /// `Block.path` for every block; a heading's path ends with its parent.
        private let paths: [String]
        private let positions: [String: Int]
        private let lock = NSLock()
        private var index: SecretaryPacket.BlockIndex?

        public init(document: String) {
            all = SecretaryPacket.blocks(document)
            parsed = all.map { SecretaryPacket.heading($0.text) }
            definitions = all.map { SecretaryPacket.isDefinition($0.text) }
            var chain: [(depth: Int, line: String)] = [], above = ""
            paths = parsed.map { heading in
                guard let heading else { return above }
                while let last = chain.last, last.depth >= heading.depth { chain.removeLast() }
                let path = chain.map(\.line).joined(separator: " › ")
                chain.append((heading.depth, String(heading.line.prefix(200))))
                above = chain.map(\.line).joined(separator: " › ")
                return path
            }
            positions = Dictionary(all.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// A block as search and block reads return it: with the path of headings above.
        private func located(_ b: SecretaryPacket.Block) -> Block {
            var block = SecretaryDocumentReader.block(b)
            if let i = positions[b.id], !paths[i].isEmpty { block.path = paths[i] }
            return block
        }

        public var blockCount: Int { all.count }

        public func outline() -> [Heading] {
            all.indices.filter { parsed[$0] != nil }.map(heading)
        }

        public func section(query: String, offset: Int = 0, byteLimit: Int = 24_000) -> SectionRead {
            let lowered = query.lowercased(), trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
            let found = all.indices.filter { i in
                guard let h = parsed[i] else { return false }
                return all[i].id == query || h.title == trimmed || h.line.lowercased() == lowered
            }
            guard found.count == 1 else {
                var candidates = found
                if found.isEmpty, !trimmed.isEmpty {
                    candidates = Array(all.indices.filter { parsed[$0]?.title.contains(trimmed) == true }.prefix(10))
                }
                return SectionRead(status: found.isEmpty ? "not_found" : "ambiguous", heading: nil, blocks: [],
                                   totalBlocks: 0, nextOffset: nil, matches: candidates.map(heading))
            }
            let start = found[0]
            let section = sectionIndices(start)
            var next = min(max(0, offset), section.count), bytes = 0
            var page: [Block] = []
            while next < section.count {
                let block = all[section[next]]
                let cost = block.text.utf8.count
                if !page.isEmpty && bytes + cost > byteLimit { break }
                page.append(SecretaryDocumentReader.block(block)); bytes += cost; next += 1
            }
            return SectionRead(status: next == section.count ? "complete" : "partial", heading: heading(start),
                               blocks: page, totalBlocks: section.count, nextOffset: next < section.count ? next : nil, matches: [])
        }

        public func find(query: String, byteLimit: Int = 24_000) -> FindRead {
            let selection = SecretaryPacket.contextSelection(index: searchIndex(), requests: [query], existing: [], limit: byteLimit)
            let report = selection.reports.first
            return FindRead(status: report?.status ?? "not_found", blocks: selection.blocks.map(located),
                            omittedForBudget: report?.omittedForBudget ?? [], unmatchedTerms: report?.unmatchedTerms ?? [])
        }

        public func find(queries: [String], byteLimit: Int = 24_000) -> MultiFindRead {
            let selection = SecretaryPacket.contextSelection(index: searchIndex(), requests: queries, existing: [], limit: byteLimit)
            return MultiFindRead(blocks: selection.blocks.map(located), reports: selection.reports.map {
                .init(query: $0.request, status: $0.status, omittedForBudget: $0.omittedForBudget, unmatchedTerms: $0.unmatchedTerms)
            })
        }

        public func blocks(ids: [String]) -> [Block] {
            let selected = Set(ids)
            return all.indices.filter { selected.contains(all[$0].id) && !definitions[$0] }
                .map { located(all[$0]) }
        }

        private func searchIndex() -> SecretaryPacket.BlockIndex {
            lock.lock(); defer { lock.unlock() }
            if let index { return index }
            let built = SecretaryPacket.BlockIndex(all, headings: parsed, definitions: definitions)
            index = built
            return built
        }

        /// The heading and every block up to the next heading of the same or higher
        /// level, without citation definitions.
        private func sectionIndices(_ start: Int) -> [Int] {
            let depth = parsed[start]?.depth ?? 0
            var end = start + 1
            while end < all.count {
                if let h = parsed[end], h.depth <= depth { break }
                end += 1
            }
            return (start..<end).filter { !definitions[$0] }
        }

        private func heading(_ index: Int) -> Heading {
            let h = parsed[index]!
            let bytes = sectionIndices(index).reduce(0) { $0 + all[$1].text.utf8.count }
            return Heading(id: all[index].id, title: h.line, depth: h.depth, bytes: bytes)
        }
    }

    // MARK: - Shared with SecretaryPacket.addressedRead

    static func headingIndices(_ all: [SecretaryPacket.Block]) -> [Int] {
        all.indices.filter { SecretaryPacket.heading(all[$0].text) != nil }
    }

    /// Exact match by heading block ID, lowercased title, or the whole heading line.
    static func sectionMatches(_ all: [SecretaryPacket.Block], query: String) -> [Int] {
        let lowered = query.lowercased(), trimmed = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
        return all.indices.filter { i in
            guard let h = SecretaryPacket.heading(all[i].text) else { return false }
            return all[i].id == query || h.title == trimmed || h.line.lowercased() == lowered
        }
    }

    /// The heading and every block up to the next heading of the same or higher level,
    /// without citation definitions.
    static func sectionBlocks(_ all: [SecretaryPacket.Block], start: Int) -> [SecretaryPacket.Block] {
        let depth = SecretaryPacket.heading(all[start].text)?.depth ?? 0
        var end = start + 1
        while end < all.count {
            if let h = SecretaryPacket.heading(all[end].text), h.depth <= depth { break }
            end += 1
        }
        return all[start..<end].filter { !SecretaryPacket.isDefinition($0.text) }
    }

    fileprivate static func block(_ b: SecretaryPacket.Block) -> Block {
        Block(id: b.id, section: b.section, text: b.text)
    }
}
