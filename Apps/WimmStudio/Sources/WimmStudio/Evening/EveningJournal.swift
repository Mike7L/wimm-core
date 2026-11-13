import Foundation

/// The evening journal's pure rules: which day an evening belongs to, how the
/// evening note's Markdown splits into sections, and how the "День" digest is
/// drawn from the day's notes. No file system here; see `EveningJournalStore`.
/// Design: `docs/Evening_Journal_Design.md`.
enum EveningJournal {
    /// An evening lasts until 4 AM: a note at 00:40 belongs to the day before.
    static let dayStartHour = 4
    static let digestHeading = "День"
    static let thoughtsHeading = "Мысли"
    /// Bumped when the fixed list changes; stored in the sidecar as `journal.source`.
    static let promptSource = "fixed-v1"
    static let prompts = [
        "Что сегодня было главным?",
        "Что осталось недоделанным?",
        "За что сегодня спасибо?",
        "Что удивило?",
        "Что было трудно?",
        "Что хочется запомнить из этого дня?",
        "С кем сегодня был хороший разговор?",
        "Что бы ты сделал иначе?",
        "Что дало энергию, а что забрало?",
        "Что завтра важнее всего?",
        "Чему научился сегодня?",
        "Где сегодня был собой?",
    ]

    // MARK: - Days

    /// The calendar day an evening at `date` belongs to (its midnight).
    static func day(containing date: Date, calendar: Calendar = .current) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -dayStartHour, to: date) ?? date
        return calendar.startOfDay(for: shifted)
    }

    /// `day` 04:00 up to the next day's 04:00.
    static func interval(for day: Date, calendar: Calendar = .current) -> DateInterval {
        let midnight = calendar.startOfDay(for: day)
        let start = calendar.date(byAdding: .hour, value: dayStartHour, to: midnight) ?? midnight
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// `2026-11-01`, the sidecar's `journal.date`.
    static func dateKey(_ day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func title(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM")
        return "Вечер, \(formatter.string(from: day))"
    }

    /// Two prompts per evening, rotating through the list by day so
    /// consecutive evenings ask different things.
    static func prompts(for day: Date, count: Int = 2, calendar: Calendar = .current) -> [String] {
        let ordinal = calendar.ordinality(of: .day, in: .era, for: day) ?? 0
        return (0..<count).map { prompts[(ordinal * count + $0) % prompts.count] }
    }

    // MARK: - Markdown

    struct Section: Equatable {
        var heading: String
        var body: String
    }

    /// The note as `# title` plus `## heading` sections. Text before the
    /// first `##` (other than the title) is kept as a section with an empty heading.
    struct Document: Equatable {
        var title: String
        var sections: [Section]

        init(title: String, sections: [Section]) {
            self.title = title
            self.sections = sections
        }

        init(markdown: String) {
            var title = ""
            var sections: [Section] = []
            var current: Section?
            var preamble: [String] = []
            for line in markdown.components(separatedBy: "\n") {
                if line.hasPrefix("## ") {
                    if let current { sections.append(current) }
                    current = Section(heading: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), body: "")
                } else if line.hasPrefix("# "), title.isEmpty, current == nil {
                    title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                } else if current != nil {
                    current!.body += (current!.body.isEmpty ? "" : "\n") + line
                } else {
                    preamble.append(line)
                }
            }
            if let current { sections.append(current) }
            sections = sections.map { Section(heading: $0.heading, body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
            let lead = preamble.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !lead.isEmpty { sections.insert(Section(heading: "", body: lead), at: 0) }
            self.title = title
            self.sections = sections
        }

        var markdown: String {
            var parts = ["# \(title)"]
            for section in sections {
                if section.heading.isEmpty {
                    parts.append(section.body)
                } else {
                    parts.append(section.body.isEmpty ? "## \(section.heading)" : "## \(section.heading)\n\n\(section.body)")
                }
            }
            return parts.joined(separator: "\n\n") + "\n"
        }

        func body(of heading: String) -> String? {
            sections.first { $0.heading == heading }?.body
        }

        /// Sets a section's body. A new question goes before "Мысли", which stays last.
        mutating func setBody(_ body: String, of heading: String) {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = sections.firstIndex(where: { $0.heading == heading }) {
                sections[index].body = trimmed
                return
            }
            let section = Section(heading: heading, body: trimmed)
            if heading == EveningJournal.thoughtsHeading {
                sections.append(section)
            } else if heading == EveningJournal.digestHeading {
                let at = sections.firstIndex { !$0.heading.isEmpty } ?? sections.count
                sections.insert(section, at: at)
            } else if let thoughts = sections.firstIndex(where: { $0.heading == EveningJournal.thoughtsHeading }) {
                sections.insert(section, at: thoughts)
            } else {
                sections.append(section)
            }
        }

        /// Skipped questions are not written: empty question sections go away.
        func droppingEmptyQuestions() -> Document {
            var copy = self
            copy.sections.removeAll {
                $0.body.isEmpty && $0.heading != EveningJournal.digestHeading && $0.heading != EveningJournal.thoughtsHeading
            }
            return copy
        }
    }

    // MARK: - Digest

    /// What the digest needs to know about one library note.
    struct DayNote: Equatable {
        enum Kind: Equatable { case voice, text, image, pdf }
        var date: Date
        var title: String
        var kind: Kind
        /// File name of the note's sidecar, the link target in the digest.
        var metadataName: String
        var minutes: Double
    }

    struct DigestLine: Equatable {
        var date: Date
        var text: String
        var notes: [String]
    }

    /// Images this close together become one "N фото" line.
    static let photoRunGap: TimeInterval = 10 * 60
    /// Titles that say nothing about a picture.
    static let genericImageTitles: Set<String> = ["Screenshot", "Pasted image", "Фото", ""]

    /// One line per note, in time order; images taken close together share a line.
    static func digest(_ notes: [DayNote], calendar: Calendar = .current) -> [DigestLine] {
        var lines: [DigestLine] = []
        var photos: [DayNote] = []
        func flushPhotos() {
            guard let first = photos.first else { return }
            let caption = photos.map(\.title).first { !genericImageTitles.contains($0) }
            let label = photos.count == 1 ? "Фото" : "\(photos.count) фото"
            let links = photos.enumerated().map { index, note in
                index == 0 ? "[\(label)](\(linkTarget(note.metadataName)))" : "[·](\(linkTarget(note.metadataName)))"
            }.joined(separator: " ")
            let text = "\(time(first.date, calendar: calendar)) — \(links)" + (caption.map { ": \(oneLine($0))" } ?? "")
            lines.append(DigestLine(date: first.date, text: text, notes: photos.map(\.metadataName)))
            photos.removeAll()
        }
        for note in notes.sorted(by: { $0.date < $1.date }) {
            if note.kind == .image {
                if let last = photos.last, note.date.timeIntervalSince(last.date) > photoRunGap { flushPhotos() }
                photos.append(note)
                continue
            }
            flushPhotos()
            var title = oneLine(note.title)
            if note.kind == .voice, note.minutes >= 1 { title += " · \(Int(note.minutes.rounded())) мин" }
            let text = "\(time(note.date, calendar: calendar)) — [\(escape(title))](\(linkTarget(note.metadataName)))"
            lines.append(DigestLine(date: note.date, text: text, notes: [note.metadataName]))
        }
        flushPhotos()
        return lines
    }

    static func digestMarkdown(_ lines: [DigestLine]) -> String {
        lines.map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// The sidecars a digest body already links to.
    static func linkedMetadataNames(in markdown: String) -> Set<String> {
        Set(orderedLinkedMetadataNames(in: markdown))
    }

    /// The sidecars a body links to, in order of first appearance.
    static func orderedLinkedMetadataNames(in markdown: String) -> [String] {
        var names: [String] = []
        var rest = Substring(markdown)
        while let open = rest.range(of: "](") {
            rest = rest[open.upperBound...]
            guard let close = rest.firstIndex(of: ")") else { break }
            let target = String(rest[..<close]).removingPercentEncoding ?? String(rest[..<close])
            if target.hasSuffix(".meta.json") {
                let name = (target as NSString).lastPathComponent
                if !names.contains(name) { names.append(name) }
            }
            rest = rest[close...]
        }
        return names
    }

    /// A spoken answer as it goes under its question: the text as heard and
    /// a link to the answer's own audio note.
    static func answerMarkdown(text: String, metadataName: String) -> String {
        let link = "[голос](\(linkTarget(metadataName)))"
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? link : "\(trimmed) (\(link))"
    }

    /// Notes the evening note cites outside the "День" digest (spoken
    /// answers, hand links). The digest does not list them again.
    static func citedMetadataNames(in document: Document) -> Set<String> {
        Set(document.sections
            .filter { $0.heading != digestHeading }
            .flatMap { orderedLinkedMetadataNames(in: $0.body) })
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private static func oneLine(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// Brackets in a title would end the link text early.
    private static func escape(_ title: String) -> String {
        title.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    /// Sidecars sit next to the evening note, so a bare file name is the relative link.
    private static func linkTarget(_ metadataName: String) -> String {
        metadataName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? metadataName
    }
}
