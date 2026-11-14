import Foundation
import Observation
import WimmDomain
import WimmInfrastructure
import WimmSecretary

/// The inbox beside the document: what changed since the owner last read it,
/// what the secretary asks, how it answered comments, and which passes ran.
@MainActor @Observable
final class StudioInboxModel {
    private(set) var baselines: [StudioInbox.Baseline] = []
    private(set) var baseline: StudioInbox.Baseline?
    private(set) var diff = StudioInbox.Diff.empty
    private(set) var questions: [StudioInbox.Question] = []
    var answerDrafts: [Int: String] = [:]
    private(set) var questionsByBlock: [Int: [StudioInbox.Question]] = [:]
    private(set) var questionBlocks: [Int: Int] = [:]
    @ObservationIgnored private var questionSourceBlocks: [String: Set<Int>] = [:]
    @ObservationIgnored private var questionMarkerBlocks: [Int: Int] = [:]

    var openQuestions: [StudioInbox.Question] {
        questions.filter { !seen.questionsSeen.contains($0.number) }
    }

    var answeredQuestions: [StudioInbox.Question] {
        let legacy = questions.filter { seen.questionsSeen.contains($0.number) && seen.answers?[$0.number] == nil }
        return (legacy + (seen.answers ?? [:]).values.map(\.question)).sorted { $0.number > $1.number }
    }

    private(set) var passes: [StudioInbox.Pass] = []
    private(set) var runBackups: [String: StudioInbox.Baseline] = [:]
    private(set) var seen = StudioInboxSeen()
    private(set) var isComputing = false
    var errorMessage: String?

    @ObservationIgnored private var documentURL: URL?
    @ObservationIgnored private var workspace: SecretaryWorkspace?
    @ObservationIgnored private var lastText: String?
    @ObservationIgnored private var fileDates: [URL: Date] = [:]
    @ObservationIgnored private var diffTask: Task<Void, Never>?

    /// Unread paragraph changes, in document order. Kept as stored values:
    /// every document block reads `changesByBlock` on each redraw.
    private(set) var changes: [StudioInbox.Change] = []
    private(set) var removals: [StudioInbox.Removal] = []
    private(set) var changesByBlock: [Int: StudioInbox.Change] = [:]
    private(set) var badgeCount = 0

    private func refreshUnread() {
        changes = diff.changes.filter { !seen.seenBlocks.contains($0.hash) }
        removals = diff.removals.filter { !seen.seenBlocks.contains($0.id) }
        changesByBlock = Dictionary(changes.map { ($0.blockID, $0) }, uniquingKeysWith: { a, _ in a })
        badgeCount = changes.count + openQuestions.count
    }

    private func refreshQuestionPlacement() {
        questionBlocks = Dictionary(uniqueKeysWithValues: (openQuestions + answeredQuestions).compactMap { question in
            StudioInbox.questionBlock(question, sourceBlocks: questionSourceBlocks, markerBlocks: questionMarkerBlocks).map { (question.number, $0) }
        })
        let placements = openQuestions.compactMap { question in
            questionBlocks[question.number].map { (block: $0, question: question) }
        }
        questionsByBlock = Dictionary(grouping: placements, by: \.block).mapValues { $0.map(\.question) }
    }

    /// Headings with an unread change somewhere below them, so a collapsed
    /// outline still shows where to look.
    func headingsWithChanges(in document: PersonalDocument) -> Set<Int> {
        StudioInbox.ancestorHeadings(of: changes.map(\.blockID) + removals.compactMap(\.nearBlockID), in: document)
    }

    func unreadReplies(in threads: [DocumentCommentThread]) -> [DocumentCommentThread] {
        let parse = ISO8601DateFormatter()
        let since = seen.repliesSeenAt.flatMap(parse.date(from:)) ?? .distantPast
        return threads.filter { thread in
            thread.replies.contains { $0.author != DocumentCommentAuthor.owner && (parse.date(from: $0.at) ?? .distantPast) > since }
        }.sorted { ($0.replies.last?.at ?? "") > ($1.replies.last?.at ?? "") }
    }

    func waiting(in threads: [DocumentCommentThread]) -> [DocumentCommentThread] {
        threads.filter { $0.status == .open && !$0.replies.contains { $0.author != DocumentCommentAuthor.owner } }
    }

    // MARK: - Loading

    func clearWorkspace() {
        diffTask?.cancel()
        documentURL = nil
        workspace = nil
        fileDates = [:]
        lastText = nil
        baseline = nil
        baselines = []
        diff = .empty
        isComputing = false
        errorMessage = nil
        passes = []
        runBackups = [:]
        questions = []
        seen = StudioInboxSeen()
        answerDrafts = [:]
        questionSourceBlocks = [:]
        questionMarkerBlocks = [:]
        refreshQuestionPlacement()
        refreshUnread()
    }

    func update(document: PersonalDocument, url: URL) {
        if documentURL != url {
            if documentURL != nil { clearWorkspace() }
            documentURL = url
            workspace = SecretaryWorkspace(document: url)
            seen = StudioInboxSeen.load(for: url)
            refreshUnread()
        }
        reloadWorkspaceFiles()
        reloadBaselines()
        if baseline == nil { baseline = defaultBaseline() }
        if lastText != document.text {
            // A paragraph ID is a position in this version of the document.
            // Drop old placements while the diff for the new version computes.
            diff = .empty
            refreshUnread()
            lastText = document.text
            questionSourceBlocks = StudioInbox.questionSourceBlocks(in: document)
            questionMarkerBlocks = StudioInbox.questionMarkerBlocks(in: document)
            refreshQuestionPlacement()
            recompute(document)
        }
    }

    /// Rereads the question queue and the pass journal when their dates change.
    func reloadWorkspaceFiles() {
        guard let root = workspace?.root else { return }
        let queue = root.appendingPathComponent("secretary/review_queue.md")
        let log = root.appendingPathComponent("secretary/change_log.md")
        if let text = readIfChanged(queue) {
            questions = StudioInbox.openQuestions(in: text)
            refreshQuestionPlacement()
            refreshUnread()
        }
        if let text = readIfChanged(log) {
            passes = StudioInbox.passes(in: text)
            runBackups = Dictionary(passes.compactMap { pass -> (String, StudioInbox.Baseline)? in
                guard let id = pass.runID, let backup = backup(ofRun: id) else { return nil }
                return (id, backup)
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    private func readIfChanged(_ url: URL) -> String? {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let date, fileDates[url] != date else { return nil }
        fileDates[url] = date
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func backup(ofRun id: String) -> StudioInbox.Baseline? {
        guard let workspace,
              let data = try? Data(contentsOf: workspace.runDirectory(id).appendingPathComponent("run.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["backup"] as? String else { return nil }
        let url = workspace.root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return StudioInbox.Baseline(kind: .backup, url: url, date: StudioInbox.backupDate(url.lastPathComponent) ?? .distantPast)
    }

    private func reloadBaselines() {
        guard let url = documentURL else { return }
        var list = StudioInbox.backups(for: url)
        let snapshot = StudioInboxSeen.snapshotURL(for: url)
        if let date = (try? snapshot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            list.insert(.init(kind: .seen, url: snapshot, date: date), at: 0)
        }
        baselines = list
    }

    /// The last "read" mark; before the first one, the newest copy made at
    /// least a day ago, so a fresh install shows the recent passes' work.
    private func defaultBaseline() -> StudioInbox.Baseline? {
        if let seen = baselines.first(where: { $0.kind == .seen }) { return seen }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        return baselines.first { $0.date <= dayAgo } ?? baselines.last
    }

    func select(_ baseline: StudioInbox.Baseline, document: PersonalDocument?) {
        self.baseline = baseline
        if let document { recompute(document) }
    }

    private func recompute(_ document: PersonalDocument) {
        diffTask?.cancel()
        guard let url = baseline?.url else { diff = .empty; refreshUnread(); return }
        isComputing = true
        diffTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> StudioInbox.Diff? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return StudioInbox.diff(baseline: text, current: document)
            }.value
            guard !Task.isCancelled else { return }
            diff = result ?? .empty
            refreshUnread()
            errorMessage = result == nil ? "Не удалось прочитать \(url.lastPathComponent)" : nil
            isComputing = false
        }
    }

    // MARK: - Marking read

    func markSeen(_ change: StudioInbox.Change) { seen.seenBlocks.insert(change.hash); persist() }
    func markSeen(_ removal: StudioInbox.Removal) { seen.seenBlocks.insert(removal.id); persist() }

    func markRepliesSeen() {
        seen.repliesSeenAt = ISO8601DateFormatter().string(from: Date())
        persist()
    }

    /// Saves the current text as the new baseline and clears per-paragraph ticks.
    func markAllRead(_ document: PersonalDocument) {
        guard let url = documentURL else { return }
        let snapshot = StudioInboxSeen.snapshotURL(for: url)
        do {
            try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(document.text.utf8).write(to: snapshot, options: .atomic)
        } catch { errorMessage = error.localizedDescription; return }
        seen.seenBlocks = []
        persist()
        reloadBaselines()
        baseline = baselines.first { $0.kind == .seen }
        recompute(document)
    }

    private func persist() {
        refreshUnread()
        if let url = documentURL { seen.save(for: url) }
    }

    // MARK: - Answers

    /// The protocol's answer route: an ordinary library note "По Q<n> — …"
    /// that the next pass reads like any other source.
    func answer(_ question: StudioInbox.Question, text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, openQuestions.contains(question) else { return nil }
        do {
            let url = try QuickNotes.saveText("По Q\(question.number) — \(trimmed)",
                                              title: "Ответ на Q\(question.number)", source: "studio-inbox-answer")
            var answers = seen.answers ?? [:]
            answers[question.number] = .init(question: question, text: trimmed)
            seen.answers = answers
            seen.questionsSeen.insert(question.number)
            answerDrafts.removeValue(forKey: question.number)
            persist()
            refreshQuestionPlacement()
            errorMessage = nil
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
