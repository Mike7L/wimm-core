import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli secretary pending`: what Wimm's `pending` marks stand for, read against the
/// library, Wimm's Trash, the registry and the document. Read-only by default.
///
/// Two gaps it names (audit 2026-11-15):
/// - No delete path touches marks, and `reconcile` only flags the registry row
///   `removed_from_wimm`, so the mark of a deleted note stays `pending` forever.
///   With `apply` Wimm clears exactly those marks whose deletion is proven: the
///   registry row carries `removed_from_wimm` (Trash proof), or, for a mark set
///   outside the registry, the note sits in Wimm's Trash. A note missing from both
///   Recordings and Trash is only reported.
/// - A `pending` source cited in the document is reported, never re-marked: the
///   mark only follows a verified receipt (AGENTS.md, Secretary bookkeeping).
public enum SecretaryPendingMarks {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        /// In the library, registry pending, not cited: the ordinary queue.
        case queued
        /// In the library, registry pending, but `[S…]` is cited in the document: a pass
        /// cited it without acknowledging it (or it was cited by hand). Re-read it in a pass.
        case citedWhilePending = "cited_while_pending"
        /// In the library, the registry already has another status: the mark lags it.
        case markBehindRegistry = "mark_behind_registry"
        /// In the library, the mark's source is not in the registry (or has none).
        case notInRegistry = "not_in_registry"
        /// Deletion proven; `apply` clears the mark.
        case closable
        /// In Wimm's Trash but the registry row is not flagged yet: run `secretary reconcile --apply` first.
        case awaitingReconcile = "awaiting_reconcile"
        /// Not in Recordings nor in Trash: no proof of a deletion; reported only.
        case missingUnproven = "missing_unproven"
    }

    public struct Row: Codable, Sendable, Equatable {
        public var file: String
        public var source: String?
        public var noteID: String
        public var presence: MarkedNotePresence
        public var registryStatus: String?
        public var registryRemoved: Bool
        public var cited: Bool
        public var verdict: Verdict
    }

    public struct Report: Codable, Sendable, Equatable {
        public var runID: String
        public var applied: Bool
        public var pending = 0
        public var counts: [String: Int] = [:]
        public var rows: [Row] = []
        public var cleared: [String] = []
        public var backup: String?
        public var findings: [String] = []
    }

    public static func audit(document: URL, apply: Bool, store: AgentMarkStore = AgentMarkStore(),
                             active: URL = FileStore.recordingsDirectory(), trash: URL = FileStore.trashDirectory(),
                             now: Date = Date()) throws -> Report {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        let id = SecretaryClock.runID(now) + "-pending"
        let lock = apply ? try SecretaryRunLock.acquire(in: workspace.runsDirectory, runID: id) : nil
        defer { lock?.release() }

        let registry = try SecretaryRegistry.parse(Data(contentsOf: SecretaryRegistry.url(document: workspace.document)))
        let text = try String(contentsOf: workspace.document, encoding: .utf8)
        let cited = citedSources(text)
        var byFile: [String: [String: Any]] = [:]
        for row in registry.rows { if let file = row["note_file"] as? String { byFile[file] = row } }

        let pending = store.marks().filter { $0.value.status == .pending }
        let presence = MarkedNotePresence.locate(pending.keys, active: active, trash: trash)
        var report = Report(runID: id, applied: apply, pending: pending.count)
        var closable: [String: AgentMarkStore.Mark] = [:]
        for (file, mark) in pending {
            let row = mark.source.flatMap { registry.byID[$0] } ?? (mark.source == nil ? byFile[file] : nil)
            let place = presence[file] ?? .missing
            let removed = row.map { SecretaryBookkeeping.flag($0["removed_from_wimm"]) } ?? false
            let status = row?["status"] as? String
            let source = mark.source ?? row?["source_id"] as? String
            let isCited = source.map(cited.contains) ?? false
            let verdict: Verdict
            switch place {
            case .library:
                if row == nil { verdict = .notInRegistry }
                else if status != "pending" { verdict = .markBehindRegistry }
                else { verdict = isCited ? .citedWhilePending : .queued }
            case .trash, .missing:
                if removed || (row == nil && mark.source == nil && place == .trash) { verdict = .closable }
                else if place == .trash { verdict = .awaitingReconcile }
                else { verdict = .missingUnproven }
            }
            if verdict == .closable { closable[file] = mark }
            report.rows.append(Row(file: file, source: source, noteID: mark.noteId, presence: place, registryStatus: status,
                                   registryRemoved: removed, cited: isCited, verdict: verdict))
            report.counts[verdict.rawValue, default: 0] += 1
        }
        report.rows.sort { ($0.verdict.rawValue, $0.source ?? "", $0.file) < ($1.verdict.rawValue, $1.source ?? "", $1.file) }

        if apply, !closable.isEmpty {
            let directory = workspace.runDirectory(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let backup = directory.appendingPathComponent("marks-before-pending.json")
            try FileManager.default.copyItem(at: store.directory.appendingPathComponent("marks.json"), to: backup)
            report.backup = workspace.relative(backup)
            report.cleared = try store.clear(ifUnchanged: closable)
            let skipped = Set(closable.keys).subtracting(report.cleared)
            for file in skipped.sorted() { report.findings.append("\(file): mark changed since it was read; left alone.") }
        }
        return report
    }

    /// `[S123]` uses in the document; reference definitions (`[S123]: …`) do not count.
    static func citedSources(_ text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\[(S[0-9]+)\](?!:)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
    }
}
