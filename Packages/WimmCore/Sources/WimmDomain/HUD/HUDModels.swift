import Foundation

public struct HUDSnapshot: Sendable, Equatable {
    public struct NoteRow: Sendable, Equatable {
        public let shortID: String
        public let createdAt: Date
        public let statusLabel: String
        public let title: String

        public init(shortID: String, createdAt: Date, statusLabel: String, title: String) {
            self.shortID = shortID
            self.createdAt = createdAt
            self.statusLabel = statusLabel
            self.title = title
        }
    }

    public let generatedAt: Date
    public let total: Int
    public let pending: Int
    public let completed: Int
    public let failedRetryable: Int
    public let failedNonRetryable: Int
    public let recent: [NoteRow]

    public init(
        generatedAt: Date,
        total: Int,
        pending: Int,
        completed: Int,
        failedRetryable: Int,
        failedNonRetryable: Int,
        recent: [NoteRow]
    ) {
        self.generatedAt = generatedAt
        self.total = total
        self.pending = pending
        self.completed = completed
        self.failedRetryable = failedRetryable
        self.failedNonRetryable = failedNonRetryable
        self.recent = recent
    }
}

public struct HUDReviewState: Sendable, Equatable {
    public let shortID: String
    public let savedAt: Date
    public let preview: String

    public init(shortID: String, savedAt: Date, preview: String) {
        self.shortID = shortID
        self.savedAt = savedAt
        self.preview = preview
    }
}

public func hudIsEmptyFailedPlaceholder(_ note: CapturedNote) -> Bool {
    guard case .failed = note.status else { return false }
    if let cardTitle = note.card?.title, !cardTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
    }
    if let title = note.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return false
    }
    return note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

public func hudPreferredRecentNotes(from notes: [CapturedNote], limit: Int) -> [CapturedNote] {
    guard limit > 0 else { return [] }
    let realNotes = notes.filter { !hudIsEmptyFailedPlaceholder($0) }
    if realNotes.count >= limit {
        return Array(realNotes.prefix(limit))
    }
    let placeholders = notes.filter(hudIsEmptyFailedPlaceholder)
    return Array((realNotes + placeholders).prefix(limit))
}

public func hudStatusLabel(for status: ProcessingStatus) -> String {
    switch status {
    case .pendingAnalysis:
        return "PENDING"
    case .completed:
        return "DONE"
    case .failed:
        return "FAILED"
    }
}

public func hudDisplayTitle(for note: CapturedNote) -> String {
    if let title = note.card?.title, !title.isEmpty { return title }
    if let title = note.title, !title.isEmpty { return title }
    let trimmed = note.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "(empty)" }
    return String(trimmed.prefix(60))
}

public func makeHUDReviewState(from note: CapturedNote) -> HUDReviewState {
    let normalized = note.text
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = normalized.isEmpty ? "(empty transcript)" : String(normalized.prefix(140))
    return HUDReviewState(shortID: note.shortID, savedAt: note.createdAt, preview: preview)
}
