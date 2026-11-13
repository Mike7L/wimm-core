import Foundation
import WimmDomain

/// What the note list is currently showing.
///
/// This replaces fourteen positional booleans on `computeVisibleIndices`, whose
/// names had drifted into two conventions (`onlyMatches`, `failedOnly` next to
/// `filterDraftsOnly`, `filterArtifactsOnly`) — with fourteen `Bool` arguments
/// in a row, transposing two was a silent bug the compiler could not see.
///
/// More importantly it gives the *predicate* one home. The Reader keeps an
/// incremental cache and re-checks a single changed note against the filters
/// without recomputing the list; that check used to be a hand-copied twin of
/// the loop inside `computeVisibleIndices`, and the two had to be edited
/// together or the fast path would disagree with the full path about what is
/// visible. Now both call `accepts(_:)`.
public struct NoteFilter: Equatable, Sendable {
    /// The raw search query. Normalized (trimmed, lowercased) on assignment.
    public var query: String {
        didSet { normalizedQuery = Self.normalize(query) }
    }
    public private(set) var normalizedQuery: String

    public var onlyMatches: Bool
    public var failedOnly: Bool
    public var suspectedNoSpeechOnly: Bool
    public var withScreenshotOnly: Bool
    public var insightsOnly: Bool
    public var favoritesOnly: Bool
    public var draftsOnly: Bool
    public var artifactsOnly: Bool
    public var unprocessedOnly: Bool
    public var importedOnly: Bool
    public var showArtifacts: Bool
    public var showCanceledNotes: Bool
    /// When set, only these notes are eligible at all (the sidebar's
    /// "selected notes" scope).
    public var noteIds: [UUID]?

    public init(
        query: String = "",
        onlyMatches: Bool = false,
        failedOnly: Bool = false,
        suspectedNoSpeechOnly: Bool = false,
        withScreenshotOnly: Bool = false,
        insightsOnly: Bool = false,
        favoritesOnly: Bool = false,
        draftsOnly: Bool = false,
        artifactsOnly: Bool = false,
        unprocessedOnly: Bool = false,
        importedOnly: Bool = false,
        showArtifacts: Bool = true,
        showCanceledNotes: Bool = false,
        noteIds: [UUID]? = nil
    ) {
        self.query = query
        self.normalizedQuery = Self.normalize(query)
        self.onlyMatches = onlyMatches
        self.failedOnly = failedOnly
        self.suspectedNoSpeechOnly = suspectedNoSpeechOnly
        self.withScreenshotOnly = withScreenshotOnly
        self.insightsOnly = insightsOnly
        self.favoritesOnly = favoritesOnly
        self.draftsOnly = draftsOnly
        self.artifactsOnly = artifactsOnly
        self.unprocessedOnly = unprocessedOnly
        self.importedOnly = importedOnly
        self.showArtifacts = showArtifacts
        self.showCanceledNotes = showCanceledNotes
        self.noteIds = noteIds
    }

    private static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether the text of a note has to be searched at all. An empty query
    /// means "no text constraint" even with `onlyMatches` on, which is what
    /// lets the Reader's incremental cache skip the expensive path.
    public var requiresTextMatch: Bool {
        onlyMatches && !normalizedQuery.isEmpty
    }

    /// Everything except the text match — the part that depends only on the
    /// note's own flags, and so can be re-checked for one note in isolation.
    public func acceptsIgnoringText(_ note: Note) -> Bool {
        if let noteIds, !noteIds.contains(note.id) { return false }
        if failedOnly, !note.isFailed { return false }
        if suspectedNoSpeechOnly, !note.suspectedNoSpeech { return false }
        if withScreenshotOnly, note.screenshotURL == nil { return false }
        if insightsOnly, !note.isInsight { return false }
        if favoritesOnly, !note.isLiked { return false }
        if draftsOnly, !note.isDraft || note.isArtifact { return false }
        if artifactsOnly {
            if !note.isArtifact { return false }
        } else if !showArtifacts, note.isArtifact {
            return false
        }
        if unprocessedOnly, !note.isUnprocessed { return false }
        if importedOnly, !note.isImported { return false }
        if !showCanceledNotes, note.isCanceled { return false }
        return true
    }
}
