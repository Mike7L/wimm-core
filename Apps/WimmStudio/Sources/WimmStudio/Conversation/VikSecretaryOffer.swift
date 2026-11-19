import Foundation

/// «Алёна» asks whether to start the secretary once the notes waiting for a pass
/// fill one packet (`Secretary.packetSourceKB`). Code only decides when to ask;
/// a pass starts on the user's spoken yes (or an explicit «Алёна, запусти
/// секретаря»), never by itself. No model call for the question or the answer.
struct VikSecretaryOffer: Equatable {
    var pending: Int
    var bytes: Int
    var at: Date

    /// A yes long after the question is no longer an answer to it.
    static let answerWindow: TimeInterval = 30 * 60

    var question: String {
        "Накопился пакет для секретаря: \(pending) \(Self.notes(pending)), около \(max(1, bytes / 1000)) КБ. " +
            "Запустить? Скажи «Алёна, да» или «Алёна, нет»."
    }

    func isFresh(now: Date = Date()) -> Bool { now.timeIntervalSince(at) <= Self.answerWindow }

    /// Ask when the backlog fills a packet; ask again only after another full packet
    /// accumulated since the last question (a «нет» is not repeated every check).
    static func shouldOffer(bytes: Int, packetBytes: Int, lastOfferedBytes: Int?) -> Bool {
        guard packetBytes > 0, bytes >= packetBytes else { return false }
        guard let last = lastOfferedBytes else { return true }
        return bytes >= last + packetBytes
    }

    static func notes(_ count: Int) -> String {
        let tens = count % 100, ones = count % 10
        if (11...14).contains(tens) { return "заметок" }
        if ones == 1 { return "заметка" }
        if (2...4).contains(ones) { return "заметки" }
        return "заметок"
    }
}

enum VikSecretaryCommand: Equatable {
    case run, decline

    /// «запусти секретаря» works any time; a bare yes/no only answers a fresh question.
    /// A longer sentence after «да» is an ordinary question, not an answer.
    static func parse(_ query: String, offered: Bool) -> VikSecretaryCommand? {
        let text = query.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if text.range(of: #"^(?:запусти|запускай|запустить|включи|начни|сделай)\s+(?:секретар[яьюе]|проход)"#,
                      options: .regularExpression) != nil { return .run }
        guard offered, !text.isEmpty, text.split(separator: " ").count <= 4 else { return nil }
        if text.range(of: #"^(?:нет|не надо|не нужно|не сейчас|не запускай|потом|позже)(?:\s|$)"#,
                      options: .regularExpression) != nil { return .decline }
        if text.range(of: #"^(?:да|давай|запускай|запусти|ага|угу|конечно|можно)(?:\s|$)"#,
                      options: .regularExpression) != nil { return .run }
        return nil
    }
}
