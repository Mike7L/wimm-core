import Foundation

/// A note Studio's session import wrote from an agent chat log (Claude, Codex,
/// Cursor, Antigravity). It is an ordinary note for search, reading and the
/// secretary (user decision 2026-11-16: journals carry results worth keeping).
///
/// The importer finds its notes again by its own marks, never by what the text
/// says: the sidecar `origin.source`, or for imports from before that key the
/// file shape (a `.txt` whose first line is a `# ` title and whose second line
/// is `Сессия <source> <uuid>`).
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

    /// A chat whose first user message is one whole JSON object is a script feeding a model
    /// (a secretary packet replayed with `claude -p`, a benchmark case), not a conversation, and
    /// the importer skips it. The `/secretary/runs/` working-directory rule misses replays started
    /// elsewhere: 124 such journals (8 MB) reached the secretary, five of them on 2026-11-20 at a
    /// paid single-source pass each (~$0.50), every one judged noise.
    public static func isScriptedPrompt(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) is [String: Any]
    }

    /// The first KB of a `.txt` note, enough for the header.
    public static func header(of file: URL) -> String? {
        guard file.pathExtension.lowercased() == "txt", let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 1024) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func isJournal(_ mediaURL: URL) -> Bool {
        if RecallSidecar.load(forRecordingURL: mediaURL)?.sidecar.originSource == Self.originSource { return true }
        return header(of: mediaURL).flatMap(sessionID(header:)) != nil
    }

    /// How long a journal must stay unchanged before the secretary is offered it.
    public static let quietSeconds: TimeInterval = 3600

    /// A journal the importer rewrote less than `quietSeconds` ago: its session may still be
    /// running, and every rewrite put it back into the pass queue (user decision 2026-11-16:
    /// offer a journal after an hour of quiet). It still counts as pending for the pass boundary.
    public static func isStillChanging(_ mediaURL: URL, now: Date = Date()) -> Bool {
        guard let modified = (try? mediaURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              now.timeIntervalSince(modified) < quietSeconds else { return false }
        return isJournal(mediaURL)
    }
}
