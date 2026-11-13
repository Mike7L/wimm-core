import Foundation
import WimmDomain

public struct NoteSelectionResult {
    public let selectedIds: Set<UUID>
    public let activeNote: Note?
    public let targetIndex: Int?

    public init(selectedIds: Set<UUID>, activeNote: Note?, targetIndex: Int?) {
        self.selectedIds = selectedIds
        self.activeNote = activeNote
        self.targetIndex = targetIndex
    }
}

public struct NoteSelectionService {
    public init() {}

    public func setSelectedNoteId(_ id: UUID?, notes: [Note]) -> NoteSelectionResult {
        guard let id else {
            return NoteSelectionResult(selectedIds: [], activeNote: nil, targetIndex: nil)
        }

        let active = notes.first(where: { $0.id == id })
        let index = notes.firstIndex(where: { $0.id == id })
        return NoteSelectionResult(
            selectedIds: [id],
            activeNote: active,
            targetIndex: index
        )
    }

    public func updateSelectedNoteId(
        currentSelected: Set<UUID>,
        id: UUID,
        additive: Bool,
        openNote: Bool,
        notes: [Note]
    ) -> NoteSelectionResult {
        let selected: Set<UUID> = additive ? currentSelected.union([id]) : [id]
        guard openNote else {
            return NoteSelectionResult(selectedIds: selected, activeNote: nil, targetIndex: nil)
        }

        let active = notes.first(where: { $0.id == id })
        let index = notes.firstIndex(where: { $0.id == id })
        return NoteSelectionResult(
            selectedIds: selected,
            activeNote: active,
            targetIndex: index
        )
    }

    public func selectAllFilteredNotes(
        visibleIndices: [Int],
        notes: [Note],
        activeNote: Note?
    ) -> NoteSelectionResult {
        let selected = Set(
            visibleIndices.compactMap { idx in
                notes.indices.contains(idx) ? notes[idx].id : nil
            }
        )

        guard !selected.isEmpty else {
            return NoteSelectionResult(selectedIds: [], activeNote: nil, targetIndex: nil)
        }

        let nextActive: Note?
        if selected.count == 1, let id = selected.first {
            nextActive = notes.first(where: { $0.id == id })
        } else if let activeNote, selected.contains(activeNote.id) {
            nextActive = activeNote
        } else {
            nextActive = nil
        }

        return NoteSelectionResult(selectedIds: selected, activeNote: nextActive, targetIndex: nil)
    }

    public func nextIndex(currentIndex: Int?, visibleIndices: [Int]) -> Int? {
        guard !visibleIndices.isEmpty else { return nil }
        guard let currentIndex, let pos = visibleIndices.firstIndex(of: currentIndex) else {
            return visibleIndices.first
        }
        let newPos = max(0, pos - 1)
        return visibleIndices[newPos]
    }

    public func previousIndex(currentIndex: Int?, visibleIndices: [Int]) -> Int? {
        guard !visibleIndices.isEmpty else { return nil }
        guard let currentIndex, let pos = visibleIndices.firstIndex(of: currentIndex) else {
            return visibleIndices.last
        }
        let newPos = min(visibleIndices.count - 1, pos + 1)
        return visibleIndices[newPos]
    }

    /// Multi-selection with Command (toggle) and Shift (range) support
    public func selectWithModifiers(
        clickedId: UUID,
        currentSelected: Set<UUID>,
        lastSelectedId: UUID?,
        isCommandPressed: Bool,
        isShiftPressed: Bool,
        visibleIndices: [Int],
        notes: [Note]
    ) -> NoteSelectionResult {
        // Shift: Range selection from last selected to clicked
        if isShiftPressed, let lastId = lastSelectedId {
            let visibleOrderedIds = visibleIndices.compactMap { idx in
                notes.indices.contains(idx) ? notes[idx].id : nil
            }

            let rangeIds: Set<UUID>
            if let clickedPos = visibleOrderedIds.firstIndex(of: clickedId),
               let lastPos = visibleOrderedIds.firstIndex(of: lastId) {
                let lower = min(clickedPos, lastPos)
                let upper = max(clickedPos, lastPos)
                rangeIds = Set(visibleOrderedIds[lower...upper])
            } else if let clickedIdx = notes.firstIndex(where: { $0.id == clickedId }),
                      let lastIdx = notes.firstIndex(where: { $0.id == lastId }) {
                let range = min(lastIdx, clickedIdx)...max(lastIdx, clickedIdx)
                rangeIds = Set(notes[range].map { $0.id })
            } else {
                // Fallback to single selection if indices not found
                return setSelectedNoteId(clickedId, notes: notes)
            }
            
            // Merge with existing selection
            let newSelected = currentSelected.union(rangeIds)
            let targetIndex = notes.firstIndex(where: { $0.id == clickedId })
            let active = newSelected.count == 1
                ? notes.first(where: { newSelected.contains($0.id) }) : nil
            return NoteSelectionResult(selectedIds: newSelected, activeNote: active, targetIndex: targetIndex)
        }
        
        // Command: Toggle selection
        if isCommandPressed {
            var newSelected = currentSelected
            if newSelected.contains(clickedId) {
                newSelected.remove(clickedId)
            } else {
                newSelected.insert(clickedId)
            }
            let active = newSelected.count == 1
                ? notes.first(where: { newSelected.contains($0.id) }) : nil
            return NoteSelectionResult(selectedIds: newSelected, activeNote: active, targetIndex: nil)
        }
        
        // A single selection immediately drives the Reader's detail pane.
        return setSelectedNoteId(clickedId, notes: notes)
    }
}
