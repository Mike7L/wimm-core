import Foundation

/// Параметры поиска заметок.
public struct NoteSearchQuery: Sendable {
    /// Полнотекстовый поиск (case-insensitive) по тексту и тайтлу заметки.
    public var text: String?
    /// Фильтр по тегу (точное совпадение, case-insensitive). Ищет в AnalysisCard.tags.
    public var tag: String?
    /// Фильтр по проекту (точное совпадение, case-insensitive). Ищет в AnalysisCard.projects.
    public var project: String?
    /// Фильтр по статусу обработки.
    public var status: ProcessingStatus?
    /// Максимальное количество результатов (nil = без ограничений).
    public var limit: Int?

    // --- Boolean flag filters (corresponds to AnalysisCard fields) ---
    /// Если true — только artifact заметки. Если false — только не-artifacts.
    public var isArtifact: Bool?
    /// Если true — только draft заметки.
    public var isDraft: Bool?
    /// Если true — только insight заметки.
    public var isInsight: Bool?
    /// Если true — только liked заметки.
    public var isLiked: Bool?
    /// Если true — только необработанные (без AnalysisCard).
    public var isUnprocessed: Bool?
    /// Если true — только заметки без project (unassigned).
    public var isUnassigned: Bool?

    public init(
        text: String? = nil,
        tag: String? = nil,
        project: String? = nil,
        status: ProcessingStatus? = nil,
        limit: Int? = nil,
        isArtifact: Bool? = nil,
        isDraft: Bool? = nil,
        isInsight: Bool? = nil,
        isLiked: Bool? = nil,
        isUnprocessed: Bool? = nil,
        isUnassigned: Bool? = nil
    ) {
        self.text = text
        self.tag = tag
        self.project = project
        self.status = status
        self.limit = limit
        self.isArtifact = isArtifact
        self.isDraft = isDraft
        self.isInsight = isInsight
        self.isLiked = isLiked
        self.isUnprocessed = isUnprocessed
        self.isUnassigned = isUnassigned
    }
}

/// Ищет заметки по тексту, тегам, проекту или статусу.
public struct SearchNotesUseCase: Sendable {
    private let storage: StoragePort

    public init(storage: StoragePort) {
        self.storage = storage
    }

    public func execute(query: NoteSearchQuery) async throws -> [CapturedNote] {
        let all = try await storage.loadAll()

        let results = all.filter { note in
            // Text search (title + transcription text)
            if let q = query.text, !q.isEmpty {
                let hay = ((note.title ?? "") + " " + note.text).lowercased()
                guard hay.contains(q.lowercased()) else { return false }
            }

            // Tag filter
            if let tag = query.tag, !tag.isEmpty {
                guard let card = note.card,
                      card.tags.contains(where: { $0.lowercased() == tag.lowercased() })
                else { return false }
            }

            // Project filter
            if let project = query.project, !project.isEmpty {
                guard let card = note.card,
                      card.projects.contains(where: { $0.lowercased() == project.lowercased() })
                else { return false }
            }

            // Status filter — compare case only, ignore associated values
            if let statusFilter = query.status {
                let sameCase: Bool
                switch (note.status, statusFilter) {
                case (.pendingAnalysis, .pendingAnalysis), (.completed, .completed), (.failed, .failed):
                    sameCase = true
                default:
                    sameCase = false
                }
                guard sameCase else { return false }
            }

            // Unprocessed filter
            if let unproc = query.isUnprocessed {
                let hasCard = note.card != nil
                if unproc && hasCard { return false }
                if !unproc && !hasCard { return false }
            }

            // Unassigned filter (no projects in AnalysisCard)
            if query.isUnassigned == true {
                let hasProject = note.card.map { !$0.projects.isEmpty } ?? false
                if hasProject { return false }
            }

            // Boolean AnalysisCard flag filters
            if !matchesFlag(query.isArtifact, of: note.card?.isArtifact) { return false }
            if !matchesFlag(query.isDraft,    of: note.card?.isDraft)    { return false }
            if !matchesFlag(query.isInsight,  of: note.card?.isInsight)  { return false }
            if !matchesFlag(query.isLiked,    of: note.card?.isLiked)    { return false }

            return true
        }

        // loadAll() guarantees createdAt-desc order; filter preserves it.
        if let limit = query.limit, limit > 0 {
            return Array(results.prefix(limit))
        }
        return results
    }

    /// Returns false when `want` is set but doesn't match `actual`
    /// (or the note has no card). Returns true when `want` is nil (no filter).
    private func matchesFlag(_ want: Bool?, of actual: Bool?) -> Bool {
        guard let want else { return true }
        guard let actual else { return false }
        return actual == want
    }
}
