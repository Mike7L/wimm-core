import CryptoKit
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

    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PersonalDocumentError: LocalizedError, Equatable, Sendable {
    case changedOnDisk
    case blockNotFound(Int)

    public var errorDescription: String? {
        switch self {
        case .changedOnDisk:
            return "The document changed on disk. Your draft is kept. Save a copy or reload before continuing."
        case .blockNotFound(let id):
            return "Block \(id) was not found in the document."
        }
    }
}

public actor PersonalDocumentStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> PersonalDocument {
        PersonalDocument(text: try String(contentsOf: url, encoding: .utf8))
    }

    private func coordinatedUpdate<T>(_ update: (String) throws -> (String, T)) throws -> T {
        var coordinationError: NSError?
        var failure: Error?
        var result: T?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                let current = try String(contentsOf: target, encoding: .utf8)
                let (next, value) = try update(current)
                if next != current {
                    try Data(next.utf8).write(to: target, options: .atomic)
                }
                result = value
            } catch { failure = error }
        }
        if let coordinationError { throw coordinationError }
        if let failure { throw failure }
        return result!
    }

    /// The equality check and replacement share a coordinated access. Another
    /// editor's changes are never silently replaced by a stale UI draft.
    public func save(_ text: String, expecting previous: String) throws {
        try coordinatedUpdate { current in
            guard current == previous else { throw PersonalDocumentError.changedOnDisk }
            return (text, ())
        }
    }

    /// Replaces one block inside a coordinated write after verifying both the file's
    /// SHA-256 digest and the target block's current Markdown SHA-256 digest.
    /// Returns the new file's SHA-256 digest.
    public func replaceBlock(
        id blockID: Int,
        with markdown: String,
        expectingSHA256 expectedSHA256: String,
        expectingBlockSHA256 expectedBlockSHA256: String
    ) throws -> String {
        let expectedFile = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let expectedBlock = expectedBlockSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return try coordinatedUpdate { current in
            guard !expectedFile.isEmpty, PersonalDocument.sha256(current) == expectedFile else {
                throw PersonalDocumentError.changedOnDisk
            }
            guard !expectedBlock.isEmpty else {
                throw PersonalDocumentError.changedOnDisk
            }
            let document = PersonalDocument(text: current)
            guard let block = document.blocks.first(where: { $0.id == blockID }) else {
                throw PersonalDocumentError.blockNotFound(blockID)
            }
            guard PersonalDocument.sha256(block.markdown) == expectedBlock else {
                throw PersonalDocumentError.changedOnDisk
            }
            guard let next = document.replacing(blockID: blockID, with: markdown) else {
                throw PersonalDocumentError.blockNotFound(blockID)
            }
            return (next, PersonalDocument.sha256(next))
        }
    }
}
