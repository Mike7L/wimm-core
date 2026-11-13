import Foundation

public struct MyDocumentEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public let noteID: UUID
    public let title: String
    public let source: String
    public let date: Date
    public let text: String
    public var generatedText: String?
    public var delivered: Bool = false
    public var marker: String { "[WIMM: \(id.uuidString)]" }
    public init(noteID: UUID, title: String, source: String, date: Date, text: String) {
        id = UUID(); self.noteID = noteID; self.title = title
        self.source = source; self.date = date; self.text = text
    }
}

/// Separate run state, never a replacement for a note's shared sidecar.
public struct MyDocumentState: Codable, Sendable {
    public var documentURL = ""
    public var model = "mlx-community/Qwen2.5-3B-Instruct-4bit"
    public var enabled = false
    public var automaticSince: Date?
    public var observedNoteIDs: Set<UUID> = []
    public var awaitingNoteIDs: Set<UUID> = []
    public var entries: [MyDocumentEntry] = []
    public init() {}

    public mutating func enqueue(_ entry: MyDocumentEntry) {
        guard !entries.contains(where: { $0.noteID == entry.noteID }) else { return }
        entries.append(entry)
    }

    public static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}
