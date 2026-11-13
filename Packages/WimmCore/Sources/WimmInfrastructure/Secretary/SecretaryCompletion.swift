import CryptoKit
import Foundation

/// Host evidence of supplied output, never a claim about the model's comprehension.
/// Kept beside get_note receipts in AgentState, outside the editable workspace.
public enum SecretaryCompletion {
    public static let reviewEnvironmentKey = "WIMM_SECRETARY_REVIEW"
    public static let queueCapability = "x-wimm-queue-receipts"

    public struct QueueReceipt: Codable {
        public let initial: Bool
        public let policy: Bool
        public let returned: Int
        public let remaining: Int

        public init(initial: Bool, policy: Bool, returned: Int, remaining: Int) {
            self.initial = initial
            self.policy = policy
            self.returned = returned
            self.remaining = remaining
        }
    }

    public struct ReviewContext: Codable, Sendable {
        public let document: URL
        public let backup: URL
        public let log: URL

        public init(document: URL, backup: URL, log: URL) {
            self.document = document
            self.backup = backup
            self.log = log
        }
    }

    public struct ReviewReceipt: Codable {
        public let before: String
        public let after: String
        public let page: Int
        public let count: Int

        public init(before: String, after: String, page: Int, count: Int) {
            self.before = before
            self.after = after
            self.page = page
            self.count = count
        }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func append<T: Encodable>(_ receipt: T, to url: URL) throws {
        try AgentStateLock.withLock(in: url.deletingLastPathComponent(), name: url.lastPathComponent) {
            if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONEncoder().encode(receipt) + Data([10]))
        }
    }

    public static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(type, from: Data($0)) }
    }

    /// Include removed text as well as the new text and nearby lines. Split long
    /// individual lines too; a receipt never covers text omitted by our renderer.
    public static func pages(before: Data, after: Data) -> [String] {
        if before == after { return [] }
        let old = String(decoding: before, as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: after, as: UTF8.self).components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        // A pure deletion must show the surviving join in the current document.
        var anchors = inserted
        var i = 0, j = 0
        while i < old.count || j < new.count {
            if j < new.count, inserted.contains(j) { j += 1 }
            else if i < old.count, removed.contains(i) {
                anchors.insert(min(j, new.count - 1)); i += 1
            } else { i += 1; j += 1 }
        }
        func render(_ lines: [String], offsets: Set<Int>, label: String) -> String {
            let context = Set(offsets.flatMap { max(0, $0 - 2)...min(lines.count - 1, $0 + 2) })
            return context.sorted().map { "\(label) L\($0 + 1) \(offsets.contains($0) ? "*" : " ") \(lines[$0])" }.joined(separator: "\n")
        }
        let output = render(old, offsets: removed, label: "BEFORE") + "\n" + render(new, offsets: anchors, label: "AFTER")
        let chars = Array(output)
        return stride(from: 0, to: chars.count, by: 8_000).map { String(chars[$0..<min($0 + 8_000, chars.count)]) }
    }

    public static func review(_ context: ReviewContext, page: Int) throws -> String {
        let before = try Data(contentsOf: context.backup), after = try Data(contentsOf: context.document)
        let pages = pages(before: before, after: after)
        guard page >= 0, page < max(1, pages.count) else { throw Failure("Invalid review page; start at page 0.") }
        let text = pages.isEmpty ? "Document unchanged; no edits to review." : pages[page]
        try append(ReviewReceipt(before: digest(before), after: digest(after), page: page, count: pages.count), to: context.log)
        return "Review page \(page + 1)/\(max(1, pages.count)); document sha256: \(digest(after)). Read every page after the final edit.\n\n" + text
    }

    public struct Failure: LocalizedError {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
