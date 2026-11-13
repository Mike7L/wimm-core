import Foundation

/// A view of an ordinary Markdown file. Source ranges keep edits local: no
/// Markdown round trip, rewritten reference definitions, or sidecar writes.
public struct PersonalDocument: Sendable {
    public struct Block: Identifiable, Sendable {
        public enum Kind: Sendable { case heading(Int), body, hidden }
        public let id: Int
        public let kind: Kind
        public let markdown: String
        public let range: NSRange
        public let anchor: String?
    }

    public let text: String
    public let blocks: [Block]
    public let references: [String: String]

    public init(text: String) {
        self.text = text
        let source = text as NSString
        let linePattern = try! NSRegularExpression(pattern: "[^\\r\\n]+(?:\\r\\n|\\n|\\r|$)|(?:\\r\\n|\\n|\\r)")
        let lines = linePattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        let reference = try! NSRegularExpression(pattern: "^\\[([^\\]]+)\\]:\\s*(\\S+)")
        let anchorPattern = try! NSRegularExpression(pattern: "^<a\\s+id=\"([^\"]+)\"\\s*></a>$")
        var refs: [String: String] = [:]
        var result: [Block] = []
        var pendingRange: NSRange?
        var pendingAnchor: String?
        var fence: String?

        func append(_ range: NSRange, kind: Block.Kind, anchor: String? = nil) {
            result.append(Block(id: result.count, kind: kind, markdown: source.substring(with: range), range: range, anchor: anchor))
        }
        func flush() {
            if let range = pendingRange { append(range, kind: .body) }
            pendingRange = nil
        }

        for match in lines {
            let full = match.range
            let raw = source.substring(with: full)
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentLength = (raw.trimmingCharacters(in: .newlines) as NSString).length
            let range = NSRange(location: full.location, length: contentLength)
            if let active = fence {
                if let start = pendingRange { pendingRange = NSUnionRange(start, range) }
                if line.hasPrefix(active) { fence = nil; flush() }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush(); fence = String(line.prefix(3)); pendingRange = range
                continue
            }
            if line.isEmpty { flush(); continue }
            let ns = line as NSString
            if let ref = reference.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                refs[ns.substring(with: ref.range(at: 1))] = ns.substring(with: ref.range(at: 2))
                append(range, kind: .hidden)
                continue
            }
            if let anchor = anchorPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush(); pendingAnchor = ns.substring(with: anchor.range(at: 1)); append(range, kind: .hidden)
                continue
            }
            if line.hasPrefix("<!--") { flush(); append(range, kind: .hidden); continue }
            let level = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(level), line.dropFirst(level).first?.isWhitespace == true {
                flush(); append(range, kind: .heading(level), anchor: pendingAnchor); pendingAnchor = nil
            } else {
                pendingRange = pendingRange.map { NSUnionRange($0, range) } ?? range
            }
        }
        flush()
        blocks = result
        references = refs
    }

    public func replacing(blockID: Int, with markdown: String) -> String? {
        guard let block = blocks.first(where: { $0.id == blockID }) else { return nil }
        return (text as NSString).replacingCharacters(in: block.range, with: markdown)
    }

    public func sources(in block: Block) -> [(id: String, target: String)] {
        let pattern = try! NSRegularExpression(pattern: "(?<!!)\\[([^\\]]+)\\](?![(:])")
        let ns = block.markdown as NSString
        var seen: Set<String> = []
        return pattern.matches(in: block.markdown, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let key = ns.substring(with: match.range(at: 1))
            guard let target = references[key], seen.insert(key).inserted else { return nil }
            return (key, target)
        }
    }

    public func displayMarkdown(for block: Block) -> String {
        var value = block.markdown
        for source in sources(in: block) { value = value.replacingOccurrences(of: "[\(source.id)]", with: "") }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PersonalDocumentError: LocalizedError {
    case changedOnDisk
    public var errorDescription: String? {
        "The document changed on disk. Your draft is kept. Save a copy or reload before continuing."
    }
}

public actor PersonalDocumentStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> PersonalDocument {
        PersonalDocument(text: try String(contentsOf: url, encoding: .utf8))
    }

    /// The equality check and replacement share a coordinated access. Another
    /// editor's changes are never silently replaced by a stale UI draft.
    public func save(_ text: String, expecting previous: String) throws {
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard try String(contentsOf: target, encoding: .utf8) == previous else {
                    throw PersonalDocumentError.changedOnDisk
                }
                try Data(text.utf8).write(to: target, options: .atomic)
            } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
    }
}
