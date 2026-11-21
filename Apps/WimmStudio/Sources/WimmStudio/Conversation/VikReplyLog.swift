import Foundation
import WimmDomain
import WimmInfrastructure

/// Alyona's saved exchanges (`Conversation/vik/<UUID>.md`): one writer, and the
/// on-demand reader behind the `my_recent_replies` tool. Nothing here is
/// attached to a request by itself: a follow-up («а подробнее?») makes the
/// model ask for it, the same way a reference to the last note makes it read
/// `previous_note`.
enum VikReplyLog {
    struct Entry: Encodable, Equatable, Sendable {
        let date: Date
        let request: String
        let answer: String
    }

    static var directory: URL { StoragePaths.baseDirectory().appendingPathComponent("Conversation/vik", isDirectory: true) }

    static func text(date: Date, source: String, request: String, answer: String, note: String, context: String) -> String {
        "# Алёна\n\(ISO8601DateFormatter().string(from: date))\nИсточник: \(source)\n\n" +
            "**Запрос:** \(request)\n\n**Алёна:** \(answer)\n\n## Текущая заметка\n\n\(note)\n\n## Прочитанный контекст\n\n\(context)\n"
    }

    /// The question and answer of one saved exchange; nil for a file of another shape.
    static func parse(_ text: String) -> Entry? {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2, lines[0] == "# Алёна",
              let date = ISO8601DateFormatter().date(from: String(lines[1])),
              let ask = text.range(of: "\n**Запрос:** "),
              let said = text.range(of: "\n\n**Алёна:** ", range: ask.upperBound..<text.endIndex) else { return nil }
        let end = text.range(of: "\n\n## Текущая заметка", range: said.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return Entry(date: date, request: String(text[ask.upperBound..<said.lowerBound]),
                     answer: String(text[said.upperBound..<end]))
    }

    /// Exchanges saved in `window` before `asOf`, newest first. Files are
    /// picked by modification date before any is opened.
    static func recent(before asOf: Date, window: TimeInterval = 2 * 3600, limit: Int = 5,
                       directory: URL = directory) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let since = asOf.addingTimeInterval(-window)
        let candidates = files.filter { $0.pathExtension == "md" }.compactMap { url -> (URL, Date)? in
            guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified >= since else { return nil }
            return (url, modified)
        }.sorted { $0.1 > $1.1 }
        return Array(candidates.lazy.compactMap { try? String(contentsOf: $0.0, encoding: .utf8) }
            .compactMap(parse).filter { $0.date >= since && $0.date <= asOf }
            .prefix(limit))
    }
}
