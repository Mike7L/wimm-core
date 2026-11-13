import CryptoKit
import Foundation
import WimmDomain
import WimmInfrastructure

/// What the secretary and agents left behind, read straight from the files
/// they already write: paragraphs changed since a baseline copy of the
/// document, open questions in `secretary/review_queue.md`, and the pass
/// journal in `secretary/change_log.md`. Nothing here writes the workspace.
enum StudioInbox {
    // MARK: - Paragraph changes

    struct Change: Identifiable, Sendable, Equatable {
        enum Kind: Sendable, Equatable { case added, edited }
        let blockID: Int
        let kind: Kind
        /// The baseline paragraph this one most likely replaced (edited only).
        let previous: String?
        let section: String?
        let text: String
        /// `StudioInbox.hash(text)`, the key a read tick is stored under.
        let hash: String
        var id: Int { blockID }

        init(blockID: Int, kind: Kind, previous: String?, section: String?, text: String) {
            self.blockID = blockID; self.kind = kind; self.previous = previous
            self.section = section; self.text = text; hash = StudioInbox.hash(text)
        }
    }

    struct Removal: Identifiable, Sendable, Equatable {
        let text: String
        /// Block of the current document closest to where the text used to be
        /// (its section heading when that survived).
        let nearBlockID: Int?
        let section: String?
        let id: String

        init(text: String, nearBlockID: Int?, section: String?) {
            self.text = text; self.nearBlockID = nearBlockID; self.section = section; id = StudioInbox.hash(text)
        }
    }

    struct Diff: Sendable, Equatable {
        var changes: [Change] = []
        var removals: [Removal] = []
        static let empty = Diff()
    }

    /// Block-level comparison. A block counts as unchanged when the same
    /// Markdown exists anywhere in the baseline, so moved paragraphs are quiet;
    /// a new block is "edited" when a vanished baseline block of the same
    /// section shares enough words with it.
    static func diff(baseline: String, current: PersonalDocument) -> Diff {
        let old = PersonalDocument(text: baseline)
        let visibleOld = old.blocks.filter { !isHidden($0) }
        let oldTexts = Set(visibleOld.map { normalized($0.markdown) })
        let newTexts = Set(current.blocks.filter { !isHidden($0) }.map { normalized($0.markdown) })
        var vanished = visibleOld.filter { !newTexts.contains(normalized($0.markdown)) }
            .map { (block: $0, section: old.section(of: $0)?.heading, words: words($0.markdown)) }

        var result = Diff()
        for block in current.blocks where !isHidden(block) && !oldTexts.contains(normalized(block.markdown)) {
            let section = current.section(of: block)?.heading
            let own = words(block.markdown)
            var best: (index: Int, score: Double)?
            for (index, candidate) in vanished.enumerated() where candidate.section == section || isHeading(block) {
                let score = similarity(own, candidate.words)
                if score >= 0.35, score > (best?.score ?? 0) { best = (index, score) }
            }
            let previous = best.map { vanished.remove(at: $0.index).block.markdown }
            result.changes.append(Change(blockID: block.id, kind: previous == nil ? .added : .edited,
                                         previous: previous, section: section, text: block.markdown))
        }
        let headings = Dictionary(current.blocks.filter(isHeading).map { (title($0), $0.id) }, uniquingKeysWith: { a, _ in a })
        result.removals = vanished.map { item in
            Removal(text: item.block.markdown, nearBlockID: item.section.flatMap { headings[$0] }, section: item.section)
        }
        return result
    }

    /// Every heading that encloses one of `blockIDs` (the heading itself included).
    static func ancestorHeadings(of blockIDs: [Int], in document: PersonalDocument) -> Set<Int> {
        var result: Set<Int> = []
        var stack: [(level: Int, id: Int)] = []
        let targets = Set(blockIDs)
        for block in document.blocks {
            if case .heading(let level) = block.kind {
                while let last = stack.last, last.level >= level { stack.removeLast() }
                stack.append((level, block.id))
            }
            if targets.contains(block.id) { result.formUnion(stack.map(\.id)) }
        }
        return result
    }

    static func isHidden(_ block: PersonalDocument.Block) -> Bool {
        if case .hidden = block.kind { return true }
        return false
    }

    static func isHeading(_ block: PersonalDocument.Block) -> Bool {
        if case .heading = block.kind { return true }
        return false
    }

    static func title(_ block: PersonalDocument.Block) -> String {
        block.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    static func normalized(_ markdown: String) -> String {
        markdown.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func hash(_ markdown: String) -> String {
        SHA256.hash(data: Data(normalized(markdown).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func words(_ text: String) -> Set<Substring> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count > 2 })
    }

    private static func similarity(_ a: Set<Substring>, _ b: Set<Substring>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    // MARK: - Baselines

    struct Baseline: Identifiable, Sendable, Equatable {
        enum Kind: Sendable, Equatable { case seen, backup }
        let kind: Kind
        let url: URL
        let date: Date
        var id: String { url.path }
    }

    /// Copies Wimm makes before every secretary run (`docs/.backups/<stem>.*before-secretary*`),
    /// newest first. The name's timestamp is the run start; the file date is older.
    static func backups(for document: URL) -> [Baseline] {
        let folder = document.deletingLastPathComponent().appendingPathComponent(".backups", isDirectory: true)
        let stem = document.deletingPathExtension().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter {
            let name = $0.lastPathComponent
            return name.hasPrefix(stem + ".") && name.contains("before-secretary") && !name.contains(".sources.")
        }.compactMap { url in
            guard let date = backupDate(url.lastPathComponent)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return Baseline(kind: .backup, url: url, date: date)
        }.sorted { $0.date > $1.date }
    }

    static func backupDate(_ name: String) -> Date? {
        // "2026-11-01-221705-before-secretary" or "20261030-manual-codex-1743-before-secretary".
        let patterns: [(String, String)] = [
            ("\\d{4}-\\d{2}-\\d{2}-\\d{6}", "yyyy-MM-dd-HHmmss"),
            ("\\d{8}-(?:[a-z]+-)*\\d{4}(?!\\d)", "yyyyMMddHHmm"),
        ]
        for (pattern, format) in patterns {
            guard let range = name.range(of: pattern, options: .regularExpression) else { continue }
            var stamp = String(name[range])
            if !format.contains("-") { stamp = stamp.filter(\.isNumber) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: stamp) { return date }
        }
        return nil
    }

    // MARK: - Questions

    struct Question: Identifiable, Sendable, Codable, Equatable {
        let number: Int
        let text: String
        let sources: [String]
        var id: Int { number }
    }

    /// Open questions: list items under "## Открытые вопросы" (until the next
    /// level-2 heading), each carrying a permanent `Q<n>`.
    static func openQuestions(in markdown: String) -> [Question] {
        var inOpen = false
        var items: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                inOpen = line.lowercased().contains("открытые вопросы")
                continue
            }
            guard inOpen else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") { items.append(String(trimmed.dropFirst(2))) }
            else if !trimmed.isEmpty, !items.isEmpty, line.hasPrefix(" ") { items[items.count - 1] += " " + trimmed }
            else if !trimmed.isEmpty { items.append("") } // prose between items ends the previous one
        }
        var seen: Set<Int> = []
        return items.compactMap { raw in
            var text = raw.replacingOccurrences(of: "**", with: "")
            guard let match = text.range(of: "^Q(\\d+)\\.\\s*", options: .regularExpression),
                  let number = Int(text[match].dropFirst().prefix(while: \.isNumber)), seen.insert(number).inserted else { return nil }
            text.removeSubrange(match)
            // A repeated "Q31." at the start is an editing slip, not content.
            if let again = text.range(of: "^Q\(number)\\.\\s*", options: .regularExpression) { text.removeSubrange(again) }
            return Question(number: number, text: text.trimmingCharacters(in: .whitespaces), sources: sourceIDs(in: text))
        }.sorted { $0.number > $1.number }
    }

    /// Only place a question when all of its document citations point to
    /// one paragraph. The discussion section itself is not evidence of placement.
    static func questionSourceBlocks(in document: PersonalDocument) -> [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        var discussionLevel: Int?
        for block in document.blocks {
            if case .heading(let level) = block.kind {
                if let current = discussionLevel, level <= current { discussionLevel = nil }
                if title(block).hasPrefix("Вопросы и наблюдения") { discussionLevel = level }
            }
            guard discussionLevel == nil, case .body = block.kind else { continue }
            for source in document.sources(in: block) {
                result[source.id, default: []].insert(block.id)
            }
        }
        return result
    }

    static func questionBlock(_ question: Question, sourceBlocks: [String: Set<Int>]) -> Int? {
        let matches = Set(question.sources.flatMap { sourceBlocks[$0] ?? [] })
        return matches.count == 1 ? matches.first : nil
    }

    static func sourceIDs(in text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "\\bS\\d+\\b")
        let ns = text as NSString
        var seen: Set<String> = []
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }.filter { seen.insert($0).inserted }
    }

    // MARK: - Pass journal

    struct Pass: Identifiable, Sendable, Equatable {
        let date: String
        let label: String
        let summary: String
        /// `secretary/runs/<id>` when the entry names a dispatcher run.
        let runID: String?
        var id: String { date + label + String(summary.prefix(40)) }
    }

    /// `change_log.md` entries — one paragraph each, "date · what · [sources ·] summary" —
    /// newest first.
    static func passes(in markdown: String, limit: Int = 30) -> [Pass] {
        markdown.components(separatedBy: "\n\n").compactMap { paragraph in
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.range(of: "^\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) != nil else { return nil }
            let parts = text.components(separatedBy: " · ")
            guard parts.count >= 2 else { return nil }
            let runID = text.range(of: "\\d{8}-\\d{6}-[0-9a-f]{4}", options: .regularExpression).map { String(text[$0]) }
            // Third field is often a long S… list; the reader wants the prose.
            let rest = Array(parts.dropFirst(2))
            let prose = rest.count > 1 && rest[0].range(of: "^[S0-9, –—-]+$", options: .regularExpression) != nil
                ? rest.dropFirst().joined(separator: " · ") : rest.joined(separator: " · ")
            // "date · what happened" alone: the second field is the whole story.
            return Pass(date: String(parts[0].prefix(16)).replacingOccurrences(of: "T", with: " "),
                        label: prose.isEmpty ? "" : parts[1], summary: prose.isEmpty ? parts[1] : prose, runID: runID)
        }.reversed().prefix(limit).map { $0 }
    }
}

/// What the owner has already looked at, kept per document outside the
/// workspace: a copy of the document as last marked read, the paragraphs
/// ticked off one by one since, and when thread replies were last seen.
struct StudioInboxSeen: Codable, Equatable {
    var seenBlocks: Set<String> = []
    var repliesSeenAt: String?
    var questionsSeen: Set<Int> = []
    var answers: [Int: Answer]?

    struct Answer: Codable, Equatable {
        let question: StudioInbox.Question
        let text: String
    }

    static func directory(for document: URL) -> URL {
        let key = SHA256.hash(data: Data(document.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return StoragePaths.baseDirectory().appendingPathComponent("AgentState/StudioInbox/\(key)", isDirectory: true)
    }

    static func snapshotURL(for document: URL) -> URL { directory(for: document).appendingPathComponent("seen.md") }
    static func stateURL(for document: URL) -> URL { directory(for: document).appendingPathComponent("seen.json") }

    static func load(for document: URL) -> StudioInboxSeen {
        guard let data = try? Data(contentsOf: stateURL(for: document)),
              let value = try? JSONDecoder().decode(StudioInboxSeen.self, from: data) else { return StudioInboxSeen() }
        return value
    }

    func save(for document: URL) {
        try? FileManager.default.createDirectory(at: Self.directory(for: document), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.stateURL(for: document), options: .atomic) }
    }
}
