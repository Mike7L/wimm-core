import Foundation

/// A note Studio's session import wrote from an agent chat log (Claude, Codex,
/// Cursor, Antigravity): a record of work with an agent, not material for the
/// knowledge base. The secretary is never offered one (user decision
/// 2026-11-15); search and reading tools still see it.
///
/// Recognised by the import's own marks, never by what the text says: the
/// sidecar `origin.source`, or for imports from before that key the file shape
/// the importer itself matches to find its notes again (a `.txt` whose first
/// line is a `# ` title and whose second line is `Сессия <source> <uuid>`).
public enum SessionJournal {
    public static let originSource = "studio-session-import"
    public static let sources = ["Codex", "Claude", "Cursor", "Antigravity"]

    /// The session id in an imported journal's header, as the importer writes it.
    public static func sessionID(header: String) -> (source: String, id: UUID)? {
        let lines = header.split(whereSeparator: \.isNewline)
        guard lines.count >= 2, lines[0].hasPrefix("# ") else { return nil }
        for source in sources {
            let marker = "Сессия \(source) "
            if lines[1].hasPrefix(marker), let id = UUID(uuidString: String(lines[1].dropFirst(marker.count))) {
                return (source, id)
            }
        }
        return nil
    }

    /// The first KB of a `.txt` note, enough for the header.
    public static func header(of file: URL) -> String? {
        guard file.pathExtension.lowercased() == "txt", let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 1024) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func isJournal(_ mediaURL: URL) -> Bool {
        let sidecar = RecallSidecar.load(forRecordingURL: mediaURL)?.sidecar
        return isJournal(mediaURL, originSource: sidecar?.originSource)
    }

    static func isJournal(_ mediaURL: URL, originSource: String?) -> Bool {
        if originSource == Self.originSource { return true }
        return header(of: mediaURL).flatMap(sessionID(header:)) != nil
    }
}
