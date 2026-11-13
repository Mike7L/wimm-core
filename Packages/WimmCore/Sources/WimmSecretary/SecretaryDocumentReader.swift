import Foundation

/// Read-only access to a personal Markdown document outside any secretary packet:
/// the outline, one section with its subsections, and literal/term search.
///
/// The secretary's addressed reads (`SecretaryPacket.addressedRead`) use the same
/// section matching and ranges, so both agree on what "a section" is. This reader
/// has no packet, budget ledger or bookkeeping: callers (`wimm-cli doc`, Studio's
/// question command) only read.
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

    public static func outline(document: String) -> [Heading] {
        let all = SecretaryPacket.blocks(document)
        return headingIndices(all).map { heading(all, at: $0) }
    }

    /// One section by exact heading block ID or heading title ("Работа" or "## Работа"),
    /// whole blocks from `offset` up to `byteLimit` (at least one block per page).
    public static func section(document: String, query: String, offset: Int = 0, byteLimit: Int = 24_000) -> SectionRead {
        let all = SecretaryPacket.blocks(document)
        let found = sectionMatches(all, query: query)
        guard found.count == 1 else {
            let candidates = found.isEmpty ? fuzzyMatches(all, query: query) : found
            return SectionRead(status: found.isEmpty ? "not_found" : "ambiguous", heading: nil, blocks: [],
                               totalBlocks: 0, nextOffset: nil, matches: candidates.map { heading(all, at: $0) })
        }
        let start = found[0]
        let section = sectionBlocks(all, start: start)
        var next = min(max(0, offset), section.count), bytes = 0
        var page: [Block] = []
        while next < section.count {
            let cost = section[next].text.utf8.count
            if !page.isEmpty && bytes + cost > byteLimit { break }
            page.append(block(section[next])); bytes += cost; next += 1
        }
        return SectionRead(status: next == section.count ? "complete" : "partial", heading: heading(all, at: start),
                           blocks: page, totalBlocks: section.count, nextOffset: next < section.count ? next : nil, matches: [])
    }

    /// The secretary's document search: literal phrases and terms, round-robin across clauses,
    /// a heading and its first body block together. Citation definitions are never returned.
    public static func find(document: String, query: String, byteLimit: Int = 24_000) -> FindRead {
        let all = SecretaryPacket.blocks(document)
        let selection = SecretaryPacket.contextSelection(blocks: all, requests: [query], existing: [], limit: byteLimit)
        let report = selection.reports.first
        return FindRead(status: report?.status ?? "not_found", blocks: selection.blocks.map(block),
                        omittedForBudget: report?.omittedForBudget ?? [], unmatchedTerms: report?.unmatchedTerms ?? [])
    }

    /// Exact blocks from the same snapshot and ID space used by outline/section.
    /// Citation definitions are not evidence blocks.
    public static func blocks(document: String, ids: [String]) -> [Block] {
        let selected = Set(ids)
        return SecretaryPacket.blocks(document)
            .filter { selected.contains($0.id) && !SecretaryPacket.isDefinition($0.text) }
            .map(block)
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

    private static func fuzzyMatches(_ all: [SecretaryPacket.Block], query: String) -> [Int] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return Array(headingIndices(all).filter { SecretaryPacket.heading(all[$0].text)!.title.contains(needle) }.prefix(10))
    }

    private static func heading(_ all: [SecretaryPacket.Block], at index: Int) -> Heading {
        let h = SecretaryPacket.heading(all[index].text)!
        let bytes = sectionBlocks(all, start: index).reduce(0) { $0 + $1.text.utf8.count }
        return Heading(id: all[index].id, title: h.line, depth: h.depth, bytes: bytes)
    }

    private static func block(_ b: SecretaryPacket.Block) -> Block {
        Block(id: b.id, section: b.section, text: b.text)
    }
}
