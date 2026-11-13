import XCTest
import WimmDomain
import WimmInfrastructure

final class NoteSelectionServiceTests: XCTestCase {
    private let service = NoteSelectionService()

    func testSetSelectedNoteIdNilClearsSelection() {
        let result = service.setSelectedNoteId(nil, notes: [])
        XCTAssertTrue(result.selectedIds.isEmpty)
        XCTAssertNil(result.activeNote)
        XCTAssertNil(result.targetIndex)
    }

    func testSetSelectedNoteIdFindsActiveAndIndex() {
        let notes = [
            makeNote(text: "a"),
            makeNote(text: "b"),
            makeNote(text: "c")
        ]
        let target = notes[1].id

        let result = service.setSelectedNoteId(target, notes: notes)
        XCTAssertEqual(result.selectedIds, [target])
        XCTAssertEqual(result.activeNote?.id, target)
        XCTAssertEqual(result.targetIndex, 1)
    }

    func testUpdateSelectedNoteIdAdditiveWithoutOpen() {
        let notes = [makeNote(text: "a"), makeNote(text: "b")]
        let current = Set([notes[0].id])

        let result = service.updateSelectedNoteId(
            currentSelected: current,
            id: notes[1].id,
            additive: true,
            openNote: false,
            notes: notes
        )

        XCTAssertEqual(result.selectedIds, Set([notes[0].id, notes[1].id]))
        XCTAssertNil(result.activeNote)
        XCTAssertNil(result.targetIndex)
    }

    func testUpdateSelectedNoteIdNonAdditiveWithOpenReplacesSelection() {
        let notes = [makeNote(text: "a"), makeNote(text: "b"), makeNote(text: "c")]
        let current = Set([notes[0].id, notes[1].id])

        let result = service.updateSelectedNoteId(
            currentSelected: current,
            id: notes[2].id,
            additive: false,
            openNote: true,
            notes: notes
        )

        XCTAssertEqual(result.selectedIds, [notes[2].id])
        XCTAssertEqual(result.activeNote?.id, notes[2].id)
        XCTAssertEqual(result.targetIndex, 2)
    }

    func testUpdateSelectedNoteIdOpenMissingNoteKeepsSelectionButNoActive() {
        let notes = [makeNote(text: "a"), makeNote(text: "b")]
        let missing = UUID()

        let result = service.updateSelectedNoteId(
            currentSelected: [],
            id: missing,
            additive: false,
            openNote: true,
            notes: notes
        )

        XCTAssertEqual(result.selectedIds, [missing])
        XCTAssertNil(result.activeNote)
        XCTAssertNil(result.targetIndex)
    }

    func testSelectAllFilteredNotesDropsActiveIfNotSelected() {
        let notes = [makeNote(text: "a"), makeNote(text: "b"), makeNote(text: "c")]
        let active = notes[0]
        let result = service.selectAllFilteredNotes(
            visibleIndices: [1, 2],
            notes: notes,
            activeNote: active
        )
        XCTAssertEqual(result.selectedIds, Set([notes[1].id, notes[2].id]))
        XCTAssertNil(result.activeNote)
    }

    func testSelectAllFilteredNotesKeepsActiveIfStillSelected() {
        let notes = [makeNote(text: "a"), makeNote(text: "b"), makeNote(text: "c")]
        let active = notes[1]
        let result = service.selectAllFilteredNotes(
            visibleIndices: [0, 1],
            notes: notes,
            activeNote: active
        )
        XCTAssertEqual(result.selectedIds, Set([notes[0].id, notes[1].id]))
        XCTAssertEqual(result.activeNote?.id, notes[1].id)
        XCTAssertNil(result.targetIndex)
    }

    func testSelectAllFilteredNotesEmptyClearsState() {
        let notes = [makeNote(text: "a")]
        let result = service.selectAllFilteredNotes(
            visibleIndices: [],
            notes: notes,
            activeNote: notes[0]
        )
        XCTAssertTrue(result.selectedIds.isEmpty)
        XCTAssertNil(result.activeNote)
        XCTAssertNil(result.targetIndex)
    }

    func testSelectAllFilteredNotesWithOneResultOpensIt() {
        let notes = [makeNote(text: "a"), makeNote(text: "b")]
        let result = service.selectAllFilteredNotes(
            visibleIndices: [1], notes: notes, activeNote: notes[0]
        )

        XCTAssertEqual(result.selectedIds, [notes[1].id])
        XCTAssertEqual(result.activeNote?.id, notes[1].id)
    }

    func testPlainClickOpensNoteOnFirstClickAndWhenReducingMultipleSelection() {
        let notes = [makeNote(text: "a"), makeNote(text: "b")]
        for selection: Set<UUID> in [[], [notes[0].id], Set(notes.map(\.id))] {
            let result = service.selectWithModifiers(
                clickedId: notes[1].id,
                currentSelected: selection,
                lastSelectedId: notes[0].id,
                isCommandPressed: false,
                isShiftPressed: false,
                visibleIndices: [0, 1],
                notes: notes
            )

            XCTAssertEqual(result.selectedIds, [notes[1].id])
            XCTAssertEqual(result.activeNote?.id, notes[1].id)
            XCTAssertEqual(result.targetIndex, 1)
        }
    }

    func testNextAndPreviousIndexFollowCurrentVisibleOrder() {
        let visible = [10, 8, 2]

        XCTAssertEqual(service.nextIndex(currentIndex: nil, visibleIndices: visible), 10)
        XCTAssertEqual(service.nextIndex(currentIndex: 8, visibleIndices: visible), 10)
        XCTAssertEqual(service.nextIndex(currentIndex: 10, visibleIndices: visible), 10)

        XCTAssertEqual(service.previousIndex(currentIndex: nil, visibleIndices: visible), 2)
        XCTAssertEqual(service.previousIndex(currentIndex: 8, visibleIndices: visible), 2)
        XCTAssertEqual(service.previousIndex(currentIndex: 2, visibleIndices: visible), 2)
    }

    func testSelectWithModifiers_CommandClickTogglesSelection() {
        let notes = [makeNote(text: "a"), makeNote(text: "b"), makeNote(text: "c")]
        let current = Set([notes[0].id, notes[1].id])

        let removeResult = service.selectWithModifiers(
            clickedId: notes[1].id,
            currentSelected: current,
            lastSelectedId: notes[0].id,
            isCommandPressed: true,
            isShiftPressed: false,
            visibleIndices: [0, 1, 2],
            notes: notes
        )
        XCTAssertEqual(removeResult.selectedIds, Set([notes[0].id]))
        XCTAssertEqual(removeResult.activeNote?.id, notes[0].id)

        let addResult = service.selectWithModifiers(
            clickedId: notes[2].id,
            currentSelected: removeResult.selectedIds,
            lastSelectedId: notes[0].id,
            isCommandPressed: true,
            isShiftPressed: false,
            visibleIndices: [0, 1, 2],
            notes: notes
        )
        XCTAssertEqual(addResult.selectedIds, Set([notes[0].id, notes[2].id]))
    }

    func testSelectWithModifiers_ShiftRangeUsesVisibleIndicesOrder() {
        let notes = [makeNote(text: "a"), makeNote(text: "b"), makeNote(text: "c"), makeNote(text: "d")]
        let visible = [0, 2, 3] // note[1] filtered out

        let result = service.selectWithModifiers(
            clickedId: notes[3].id,
            currentSelected: [],
            lastSelectedId: notes[0].id,
            isCommandPressed: false,
            isShiftPressed: true,
            visibleIndices: visible,
            notes: notes
        )

        XCTAssertEqual(result.selectedIds, Set([notes[0].id, notes[2].id, notes[3].id]))
        XCTAssertEqual(result.targetIndex, 3)
    }

    func testSelectWithModifiers_ShiftWithoutAnchorFallsBackToSingleSelection() {
        let notes = [makeNote(text: "a"), makeNote(text: "b")]

        let result = service.selectWithModifiers(
            clickedId: notes[1].id,
            currentSelected: [notes[0].id],
            lastSelectedId: nil,
            isCommandPressed: false,
            isShiftPressed: true,
            visibleIndices: [0, 1],
            notes: notes
        )

        XCTAssertEqual(result.selectedIds, [notes[1].id])
        XCTAssertEqual(result.activeNote?.id, notes[1].id)
    }

    private func makeNote(text: String) -> Note {
        let id = UUID()
        return Note(
            id: id,
            index: 0,
            fileURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).txt"),
            fileCreated: Date(),
            start: 0,
            end: 1,
            text: text,
            isFailed: false,
            hasRaw: false
        )
    }
}
