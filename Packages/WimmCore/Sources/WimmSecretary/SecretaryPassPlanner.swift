import Foundation
import WimmInfrastructure

/// Whether a full pass has anything to decide, answered from Wimm's own data
/// (the agent's marks, the pass boundary, file times) without a model call.
/// A note is pending when it changed at or after the stored boundary and is
/// either unmarked, or marked but with content that differs from the mark's
/// fingerprint *and* a new transcript or a human edit since the boundary. That
/// is exactly what the pass prompt asks `changed_notes` for
/// (`skip_unchanged_marked` plus `marked_changes: "transcript,edited"`), so a
/// re-analysis, a sync or a late OCR pass does not wake the agent. It counts
/// only what preparation would offer: a settled note whose re-run only moved
/// punctuation, a note under an explicit user hold and an imported agent session
/// journal (`SessionJournal`) are not pending, or they
/// would pin the boundary for good (2026-11: it stayed at 10-25 for weeks).
public struct SecretaryPassScan: Sendable, Equatable {
    public var boundary: Date
    public var pending: Int
    /// Of `pending`: never marked.
    public var unmarked = 0
    /// Oldest change among the pending notes; the boundary may advance no further.
    public var oldestPending: Date?
}

public enum SecretaryPassPlanner {
    /// nil when no boundary is stored: nothing says what is new, so the pass runs.
    public static func scan(
        marks: AgentMarkStore = AgentMarkStore(),
        initialBoundary: Date? = nil,
        recordings: (() async -> [URL])? = nil,
        lastChange: ((URL) -> Date?)? = nil,
        fingerprint: ((URL) -> NoteFingerprint)? = nil,
        kinds: ((URL, Date) -> [NoteChangeKind])? = nil,
        held: (URL) -> Bool = { _ in false },
        journal: (URL) -> Bool = SessionJournal.isJournal
    ) async -> SecretaryPassScan? {
        let recordings = recordings ?? { await FileRepository().recordings() }
        let lastChange = lastChange ?? { LibraryRecallSource.lastChange(of: $0) }
        let changedMarkedNote: (URL, Date, AgentMarkStore.Mark) -> Bool
        if fingerprint == nil && kinds == nil {
            changedMarkedNote = { NoteFingerprint.changedForPass($0, since: $1, mark: $2) }
        } else {
            let fingerprint = fingerprint ?? { NoteFingerprint.read(forRecordingURL: $0) }
            let kinds = kinds ?? { NoteChangeKind.kinds(forRecordingURL: $0, since: $1) }
            changedMarkedNote = { url, boundary, mark in
                guard NoteFingerprint.needsPass(mark: mark, now: fingerprint(url)) else { return false }
                let changes = kinds(url, boundary)
                return changes.contains(.transcript) || changes.contains(.edited)
            }
        }
        guard let boundary = marks.pass()?.asOf ?? initialBoundary else { return nil }
        let known = marks.marks()
        var pending = 0
        var unmarked = 0
        var oldest: Date?
        for url in await recordings() {
            guard let changed = lastChange(url), changed >= boundary else { continue }
            // Preparation never offers a held note or a session journal, so neither may pin the boundary.
            guard !held(url), !journal(url) else { continue }
            if let mark = known[url.lastPathComponent] {
                guard changedMarkedNote(url, boundary, mark) else { continue }
            } else {
                unmarked += 1
            }
            pending += 1
            oldest = min(oldest ?? changed, changed)
        }
        return SecretaryPassScan(boundary: boundary, pending: pending, unmarked: unmarked, oldestPending: oldest)
    }

    /// Where the boundary can move after a clean pass that started at `started`:
    /// up to the start when nothing is left pending, else only to the oldest
    /// note still waiting. Never backwards.
    public static func advancedBoundary(after scan: SecretaryPassScan, started: Date) -> Date? {
        let target = min(started, scan.oldestPending ?? started)
        return target > scan.boundary ? target : nil
    }
}
