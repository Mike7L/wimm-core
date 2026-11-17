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
/// punctuation and a note under an explicit user hold are not pending, or they
/// would pin the boundary for good (2026-11: it stayed at 10-25 for weeks).
public struct SecretaryPassScan: Sendable, Equatable {
    public var boundary: Date
    public var pending: Int
    /// Of `pending`: never marked.
    public var unmarked = 0
    /// Oldest change among the pending notes; the boundary may advance no further.
    public var oldestPending: Date?
}

/// One note of the queue as `prepare` saw it: saved with the file session so `apply`
/// can tell what is left without listing the library again.
public struct SecretaryWaitingNote: Codable, Sendable, Equatable {
    public var file: String
    /// The note's last change when the queue was built.
    public var changed: Date
    /// Fingerprints of the mark it had then; nil when it was unmarked.
    public var markText: String?
    public var markAnalysis: String?
}

public enum SecretaryPassPlanner {
    /// What is left of the queue `prepare` saved, read from the marks alone: a note is
    /// settled once it has a mark it did not have then. A note that appeared or changed
    /// after `prepare` changed after the pass started, and the boundary never moves past
    /// the start, so the next `prepare` still finds it.
    static func remaining(of waiting: [SecretaryWaitingNote], marks: AgentMarkStore) -> SecretaryPassScan {
        let known = marks.marks()
        var scan = SecretaryPassScan(boundary: marks.pass()?.asOf ?? .distantPast, pending: 0)
        for note in waiting {
            let mark = known[note.file]
            if let mark, note.markText == nil || mark.text != note.markText || mark.analysis != note.markAnalysis { continue }
            scan.pending += 1
            if mark == nil { scan.unmarked += 1 }
            scan.oldestPending = min(scan.oldestPending ?? note.changed, note.changed)
        }
        return scan
    }

    /// What the packet header promises: the saved queue without the notes of this portion.
    /// It is what `remaining(of:marks:)` answers after an apply that settles every one of them.
    static func remaining(of waiting: [SecretaryWaitingNote], afterPortion files: Set<String>) -> Int {
        waiting.count { !files.contains($0.file) }
    }

    /// The library never lists a canceled recording (`LibraryRecallSource.build`), so no
    /// packet offers it and it must not count as pending either.
    public static func isCanceled(_ url: URL) -> Bool {
        RecallSidecar.load(forRecordingURL: url)?.sidecar.isCanceled == true
    }

    /// nil when no boundary is stored: nothing says what is new, so the pass runs.
    public static func scan(
        marks: AgentMarkStore = AgentMarkStore(),
        initialBoundary: Date? = nil,
        recordings: (() async -> [URL])? = nil,
        lastChange: ((URL) -> Date?)? = nil,
        fingerprint: ((URL) -> NoteFingerprint)? = nil,
        kinds: ((URL, Date) -> [NoteChangeKind])? = nil,
        held: (URL) -> Bool = { _ in false },
        canceled: (URL) -> Bool = SecretaryPassPlanner.isCanceled
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
            // Preparation never offers a held note, so it must not pin the boundary either.
            guard !held(url) else { continue }
            let mark = known[url.lastPathComponent]
            if let mark { guard changedMarkedNote(url, boundary, mark) else { continue } }
            // Last: it reads the sidecar, and only a note about to count needs it.
            guard !canceled(url) else { continue }
            if mark == nil { unmarked += 1 }
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
