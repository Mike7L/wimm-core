import Foundation

/// Questions to the user in `secretary/review_queue.md`: list items under
/// "## Открытые вопросы", each with a permanent `Q<n>`.
///
/// A question may carry answer options as a sub-list, so the owner can answer
/// with one tap (format: `docs/Secretary_Question_Options_Proposal_2026-11-20.md`):
///
///     - **Q58. Работа.** Куда поставить абзац про клуб? [S12]
///       - a) Оставить в «Работе»
///         - плюс: рядом с датами
///         - минус: глава уже длинная
///       - b) Перенести в «Друзья»
///       - Рекомендую: b — там уже есть вся история клуба.
///
/// A question without a valid sub-list is plain text, as before. The web feed
/// has a port of this parser (`Apps/WimmStudioWeb/server/inboxApi.ts`,
/// `parseQuestions`): keep both in step.
public enum SecretaryReviewQueue {
    public struct Option: Codable, Sendable, Equatable {
        /// Short key the answer names: `a`, `b`, `1`… (lowercased).
        public let key: String
        public let label: String
        public var pros: [String]?
        public var cons: [String]?

        public init(key: String, label: String, pros: [String]? = nil, cons: [String]? = nil) {
            self.key = key; self.label = label; self.pros = pros; self.cons = cons
        }
    }

    public struct Question: Identifiable, Codable, Sendable, Equatable {
        public let number: Int
        public let text: String
        public let sources: [String]
        /// At least two options with distinct keys, or nil for a free-text question.
        public var options: [Option]?
        /// Key of the option the secretary recommends, with its reason.
        public var recommend: String?
        public var why: String?
        public var id: Int { number }

        public init(number: Int, text: String, sources: [String], options: [Option]? = nil,
                    recommend: String? = nil, why: String? = nil) {
            self.number = number; self.text = text; self.sources = sources
            self.options = options; self.recommend = recommend; self.why = why
        }
    }

    /// What a one-tap answer says; the note is "По Q<n> — " + this, the same
    /// route as a typed answer.
    public static func answerText(for option: Option) -> String {
        "вариант \(option.key): \(option.label)"
    }

    public static func openQuestions(in markdown: String) -> [Question] {
        var inOpen = false
        var drafts: [Draft] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                inOpen = line.lowercased().contains("открытые вопросы")
                continue
            }
            guard inOpen else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                let body = String(trimmed.dropFirst(2))
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                if let last = drafts.indices.last, !drafts[last].text.isEmpty, indent > drafts[last].indent,
                   first(questionStart, in: plain(body)) == nil {
                    drafts[last].absorb(plain(body))
                } else {
                    drafts.append(Draft(text: body, indent: indent))
                }
            } else if !trimmed.isEmpty, let last = drafts.indices.last, line.hasPrefix(" ") {
                drafts[last].continueLine(trimmed)
            } else if !trimmed.isEmpty {
                drafts.append(Draft(text: "", indent: 0)) // prose between items ends the previous one
            }
        }
        var seen: Set<Int> = []
        return drafts.compactMap { draft in
            var text = draft.text.replacingOccurrences(of: "**", with: "")
            guard let match = text.range(of: "^Q(\\d+)\\.\\s*", options: .regularExpression),
                  let number = Int(text[match].dropFirst().prefix(while: \.isNumber)), seen.insert(number).inserted else { return nil }
            text.removeSubrange(match)
            // A repeated "Q31." at the start is an editing slip, not content.
            if let again = text.range(of: "^Q\(number)\\.\\s*", options: .regularExpression) { text.removeSubrange(again) }
            let options = draft.options.count >= 2 && Set(draft.options.map(\.key)).count == draft.options.count ? draft.options : nil
            let recommend = draft.recommend.flatMap { key in options?.contains { $0.key == key } == true ? key : nil }
            return Question(number: number, text: text.trimmingCharacters(in: .whitespaces), sources: sourceIDs(in: text),
                            options: options, recommend: recommend, why: recommend == nil ? nil : draft.why)
        }.sorted { $0.number > $1.number }
    }

    public static func sourceIDs(in text: String) -> [String] {
        let ns = text as NSString
        var seen: Set<String> = []
        return sourceID.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }.filter { seen.insert($0).inserted }
    }

    /// The queue item for a new question. Option lines the writer put on
    /// their own lines stay a sub-list when they make a valid structured
    /// question; anything else is one line, as before.
    public static func item(number: Int, question: String) -> String {
        let flat = "- Q\(number). \(question.replacingOccurrences(of: "\n", with: " "))"
        var head: [String] = []
        var subs: [(indent: Int, text: String)] = []
        for line in question.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- ") { subs.append((line.prefix { $0 == " " || $0 == "\t" }.count, trimmed)) }
            else if subs.isEmpty { head.append(trimmed) }
            else { return flat }
        }
        guard !head.isEmpty, let base = subs.map(\.indent).min() else { return flat }
        let structured = "- Q\(number). \(head.joined(separator: " "))\n"
            + subs.map { ($0.indent > base ? "    " : "  ") + $0.text }.joined(separator: "\n")
        return openQuestions(in: "## Открытые вопросы\n\n\(structured)\n").first?.options != nil ? structured : flat
    }

    // MARK: - Sub-list lines

    private struct Draft {
        enum Target { case text, option, why, none }
        var text: String
        let indent: Int
        var options: [Option] = []
        var recommend: String?
        var why: String?
        var target = Target.text

        mutating func absorb(_ line: String) {
            if let found = first(recommendLine, in: line) {
                recommend = found[0].lowercased()
                why = found[1].isEmpty ? nil : found[1]
                target = .why
            } else if let found = first(whyLine, in: line) {
                why = found[0]
                target = .why
            } else if let found = first(optionLine, in: line) {
                options.append(Option(key: found[0].lowercased(), label: found[1]))
                target = .option
            } else if !options.isEmpty, let found = first(proLine, in: line) {
                options[options.count - 1].pros = (options[options.count - 1].pros ?? []) + [found[0]]
                target = .none
            } else if !options.isEmpty, let found = first(conLine, in: line) {
                options[options.count - 1].cons = (options[options.count - 1].cons ?? []) + [found[0]]
                target = .none
            } else {
                target = .none
            }
        }

        mutating func continueLine(_ line: String) {
            switch target {
            case .text: text += " " + line
            case .option:
                let last = options.removeLast()
                options.append(Option(key: last.key, label: last.label + " " + plain(line), pros: last.pros, cons: last.cons))
            case .why: why = [why, plain(line)].compactMap { $0 }.joined(separator: " ")
            case .none: break
            }
        }
    }

    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let sourceID = regex(#"\bS\d+\b"#)
    private static let questionStart = regex(#"^Q\d+\."#)
    private static let optionLine = regex(#"^([\p{L}\p{N}]{1,3})\)\s+(.+)$"#)
    private static let recommendLine = regex(#"^(?:рекомендую|рекомендация|recommend)\s*:\s*([\p{L}\p{N}]{1,3})\)?(?:\s*[—–:.,-]\s*|\s+|$)(.*)$"#)
    private static let whyLine = regex(#"^(?:почему|причина|why)\s*:\s*(.+)$"#)
    private static let proLine = regex(#"^(?:(?:плюс|за|pro)\s*:|\+)\s*(.+)$"#)
    private static let conLine = regex(#"^(?:(?:минус|против|con)\s*:|[−–])\s*(.+)$"#)

    /// Capture groups of the first match, trimmed.
    private static func first(_ regex: NSRegularExpression, in line: String) -> [String]? {
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<match.numberOfRanges).map {
            let range = match.range(at: $0)
            return range.location == NSNotFound ? "" : ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        }
    }
}
