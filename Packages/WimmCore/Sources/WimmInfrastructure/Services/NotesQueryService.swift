import Foundation
import WimmDomain
import NaturalLanguage

public struct NotesQueryService: Sendable {
    public init() {}

    public func searchIndices(
        notes: [Note],
        query: String,
        searchInTitle: Bool = true,
        searchInSummary: Bool = true,
        searchInText: Bool = true,
        searchInId: Bool = true
    ) -> [Int] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return Array(notes.indices) }
        return notes.indices.filter {
            matches(
                note: notes[$0],
                query: normalized,
                searchInTitle: searchInTitle,
                searchInSummary: searchInSummary,
                searchInText: searchInText,
                searchInId: searchInId
            )
        }
    }

    public func textMatchIndices(notes: [Note], query: String) -> [Int] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return [] }
        return searchIndices(notes: notes, query: normalized)
    }

    public func nextSearchIndex(hits: [Int], currentIndex: Int?) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let currentIndex else { return hits.first }
        if let next = hits.first(where: { $0 > currentIndex }) { return next }
        return hits.first
    }

    public func computeVisibleIndices(
        notes: [Note], filter: NoteFilter, textMatchIndices: [Int]? = nil
    ) -> [Int] {
        let isProfiling = Profiler.isEnabled
        let phaseToken = UUID().uuidString
        if isProfiling {
            Profiler.shared.record("visibleIndices.notesCount", value: Double(notes.count))
            Profiler.shared.record("visibleIndices.queryLength", value: Double(filter.normalizedQuery.count))
            Profiler.shared.start("visibleIndices.phase.filter", id: phaseToken)
        }

        let shouldMatchText = filter.requiresTextMatch
        let preparedHits = textMatchIndices.map { Set($0) }
        var filtered: [(index: Int, absoluteDate: Date)] = []
        filtered.reserveCapacity(notes.count)

        for (idx, note) in notes.enumerated() {
            guard filter.acceptsIgnoringText(note) else { continue }
            if shouldMatchText, let preparedHits {
                guard preparedHits.contains(idx) else { continue }
            } else if shouldMatchText,
                !matches(
                    note: note,
                    query: filter.normalizedQuery,
                    searchInTitle: true,
                    searchInSummary: true,
                    searchInText: true,
                    searchInId: true
                )
            {
                continue
            }

            filtered.append((idx, note.absoluteDate))
        }


        if isProfiling {
            Profiler.shared.record("visibleIndices.filteredCount", value: Double(filtered.count))
            Profiler.shared.end("visibleIndices.phase.filter", id: phaseToken)
            Profiler.shared.start("visibleIndices.phase.sort", id: phaseToken)
        }

        if filtered.count > 1 {
            filtered.sort { $0.absoluteDate > $1.absoluteDate }
        }

        if isProfiling {
            Profiler.shared.end("visibleIndices.phase.sort", id: phaseToken)
        }

        return filtered.map(\.index)
    }

    private func matches(
        note: Note,
        query: String,
        searchInTitle: Bool,
        searchInSummary: Bool,
        searchInText: Bool,
        searchInId: Bool
    ) -> Bool {
        let inTitle = searchInTitle && (note.title?.lowercased().contains(query) ?? false)
        let inSummary = searchInSummary && (note.summary?.lowercased().contains(query) ?? false)
        let inText = searchInText && note.text.lowercased().contains(query)
        let inFileName = searchInText
            && note.fileURL.lastPathComponent.lowercased().contains(query)
        let inMetadata = searchInText && note.metadataSearchText.contains(query)
        let inId = searchInId && note.id.uuidString.lowercased().contains(query)
        return inTitle || inSummary || inText || inFileName || inMetadata || inId
    }

}
