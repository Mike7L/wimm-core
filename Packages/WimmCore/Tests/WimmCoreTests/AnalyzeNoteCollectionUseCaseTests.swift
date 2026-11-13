import XCTest
import WimmDomain

final class AnalyzeNoteCollectionUseCaseTests: XCTestCase {
    func testExecuteLoadsRequestedNotesInInputOrder() async throws {
        let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let notes = [
            CapturedNote(
                id: secondID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_100),
                text: "Second note",
                audioPath: "second.m4a",
                status: .completed
            ),
            CapturedNote(
                id: firstID,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                text: "First note",
                audioPath: "first.m4a",
                status: .completed
            )
        ]
        let storage = AnalyzeNoteCollectionStorageStub(notes: notes)
        let answering = AnalyzeNoteCollectionAnsweringStub(answer: "Combined answer")
        let useCase = AnalyzeNoteCollectionUseCase(storage: storage, answering: answering)

        let result = try await useCase.execute(
            noteIDs: [firstID, secondID],
            rawQuestion: "Вопрос: что общего у этих заметок?",
            role: "analyst",
            outputLanguage: "Russian"
        )

        XCTAssertEqual(result.noteIDs, [firstID, secondID])
        XCTAssertEqual(result.normalizedQuestion, "что общего у этих заметок?")
        XCTAssertEqual(result.answer, "Combined answer")

        let snapshot = await answering.snapshot()
        XCTAssertEqual(snapshot.question, "что общего у этих заметок?")
        XCTAssertEqual(snapshot.noteIDs, [firstID, secondID])
        XCTAssertEqual(snapshot.role, "analyst")
        XCTAssertEqual(snapshot.outputLanguage, "Russian")
    }
}

private final class AnalyzeNoteCollectionStorageStub: StoragePort, @unchecked Sendable {
    private let notes: [CapturedNote]

    init(notes: [CapturedNote]) {
        self.notes = notes
    }

    func saveRecording(data: Data, fileName: String, initialText: String) async throws -> CapturedNote {
        _ = data
        _ = fileName
        _ = initialText
        fatalError("Unused in test")
    }

    func loadAll() async throws -> [CapturedNote] {
        notes
    }

    func updateNote(_ note: CapturedNote) async throws {
        _ = note
    }

    func deleteNote(id: UUID) async throws {
        _ = id
    }

    func loadNote(matchingAudioPath audioPath: String) async throws -> CapturedNote? {
        _ = audioPath
        return nil
    }


}

private actor AnalyzeNoteCollectionAnsweringStub: NoteCollectionAnsweringPort {
    private let fixedAnswer: String
    private var lastQuestion: String?
    private var lastNoteIDs: [UUID] = []
    private var lastRole: String?
    private var lastOutputLanguage: String?

    init(answer: String) {
        self.fixedAnswer = answer
    }

    func answer(
        question: String,
        notes: [CapturedNote],
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        lastQuestion = question
        lastNoteIDs = notes.map(\.id)
        lastRole = role
        lastOutputLanguage = outputLanguage
        return fixedAnswer
    }

    func snapshot() -> (question: String?, noteIDs: [UUID], role: String?, outputLanguage: String?) {
        (lastQuestion, lastNoteIDs, lastRole, lastOutputLanguage)
    }
}
