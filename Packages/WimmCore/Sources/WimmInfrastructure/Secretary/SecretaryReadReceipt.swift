import Foundation

/// A local receipt of the exact version returned by get_note. Never sent to a model.
/// Stays in WimmInfrastructure because MCP get_note writes it; the secretary target only reads it.
public struct SecretaryReadReceipt: Codable, Sendable {
    public let file: String
    public let sidecar: String
    public let noteID: String
    public let sha256: String
    public let text: String
    public let analysis: String
    /// Coverage of the rendered response, not merely fields present on disk.
    /// nil on legacy receipts: their version is known, their read scope is not.
    public var suppliedText: [TextCoverage]?
    /// Set when a secretary packet showed only a labeled triage preview (head and tail) of a
    /// source above the solo limit. `suppliedText` still describes the whole rendering; a partial
    /// view can only mark the note "not a note" (noise), never count as read.
    public var partialView: PartialView?

    public struct PartialView: Codable, Sendable, Equatable {
        public let totalBytes: Int
        public let headBytes: Int
        public let tailBytes: Int

        public init(totalBytes: Int, headBytes: Int, tailBytes: Int) {
            self.totalBytes = totalBytes
            self.headBytes = headBytes
            self.tailBytes = tailBytes
        }
    }

    /// The whole rendered text reached the reader.
    public var wholeTextSupplied: Bool { allAvailableTextSupplied && partialView == nil }

    public struct TextCoverage: Codable, Sendable {
        public let block: Int
        public let label: String
        public let transcriptKind: String?
        /// full, duplicate, truncated, omitted; default_status / fallback_copy: see `suppliedStates`.
        public let state: String

        public init(block: Int, label: String, transcriptKind: String?, state: String) {
            self.block = block
            self.label = label
            self.transcriptKind = transcriptKind
            self.state = state
        }
    }

    public init(file: String, sidecar: String, noteID: String, sha256: String, text: String, analysis: String,
                suppliedText: [TextCoverage]? = nil, partialView: PartialView? = nil) {
        self.file = file
        self.sidecar = sidecar
        self.noteID = noteID
        self.sha256 = sha256
        self.text = text
        self.analysis = analysis
        self.suppliedText = suppliedText
        self.partialView = partialView
    }

    /// Coverage states that count as supplied. `default_status` and `fallback_copy` blocks are
    /// packet omissions of text that only restates a default or the transcript above.
    public static let suppliedStates: Set<String> = ["full", "duplicate", "default_status", "fallback_copy"]

    public var allAvailableTextSupplied: Bool {
        guard let suppliedText else { return false }
        return suppliedText.allSatisfy { Self.suppliedStates.contains($0.state) }
    }

    public var localVariantSupplied: Bool? {
        guard let suppliedText else { return nil }
        return suppliedText.contains {
            ["local", "realtime"].contains($0.transcriptKind ?? "")
                && ($0.state == "full" || $0.state == "duplicate")
        }
    }

    public static let capability = "x-wimm-read-receipts"
    public static let coverageCapability = "x-wimm-text-coverage"

    public static func logURL(runID: String, store: AgentMarkStore = AgentMarkStore()) -> URL {
        store.directory.appendingPathComponent("SecretaryReads/\(runID).jsonl")
    }

    public func append(to url: URL) throws {
        // A new MCP process can start during the same run; append under the shared lock.
        try AgentStateLock.withLock(in: url.deletingLastPathComponent(), name: url.lastPathComponent) {
            let line = try JSONEncoder().encode(self) + Data([10])
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }
}
