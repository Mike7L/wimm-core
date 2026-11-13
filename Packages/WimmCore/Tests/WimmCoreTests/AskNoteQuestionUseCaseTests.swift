import XCTest
import WimmDomain

final class AskNoteQuestionUseCaseTests: XCTestCase {
    func testNormalizeQuestionStripsCombinedPrefixes() {
        let normalized = AskNoteQuestionUseCase.normalizeQuestion(
            "Ответ на вопрос. Вопрос: как готовить рис?"
        )
        XCTAssertEqual(normalized, "как готовить рис?")
    }

    func testNormalizeQuestionLeavesPlainQuestionUntouched() {
        let normalized = AskNoteQuestionUseCase.normalizeQuestion("Как готовить рис?")
        XCTAssertEqual(normalized, "Как готовить рис?")
    }

    func testExecuteLoadsNoteAndReturnsNormalizedQuestion() async throws {
        let noteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let note = CapturedNote(
            id: noteID,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            text: "Рис нужно промыть и варить на медленном огне.",
            audioPath: "note.m4a",
            status: .completed
        )
        let storage = AskNoteQuestionStorageStub(notes: [note])
        let answering = AskNoteQuestionAnsweringStub(answer: "Промой рис и вари на медленном огне.")
        let useCase = AskNoteQuestionUseCase(storage: storage, answering: answering)

        let result = try await useCase.execute(
            noteID: noteID,
            rawQuestion: "Ответ на вопрос. Вопрос: как готовить рис?",
            role: "solver",
            outputLanguage: "Russian"
        )

        XCTAssertEqual(result.noteID, noteID)
        XCTAssertEqual(result.normalizedQuestion, "как готовить рис?")
        XCTAssertEqual(result.answer, "Промой рис и вари на медленном огне.")
    let snapshot = await answering.snapshot()
    XCTAssertEqual(snapshot.question, "как готовить рис?")
    XCTAssertEqual(snapshot.role, "solver")
    XCTAssertEqual(snapshot.outputLanguage, "Russian")
    }
}

private final class AskNoteQuestionStorageStub: StoragePort, @unchecked Sendable {
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

private actor AskNoteQuestionAnsweringStub: QuestionAnsweringPort {
    private let fixedAnswer: String
    private var lastQuestion: String?
    private var lastRole: String?
    private var lastOutputLanguage: String?

    init(answer: String) {
        self.fixedAnswer = answer
    }

    func answer(
        question: String,
        note: CapturedNote,
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        _ = note
        lastQuestion = question
        lastRole = role
        lastOutputLanguage = outputLanguage
        return fixedAnswer
    }

    func snapshot() -> (question: String?, role: String?, outputLanguage: String?) {
        (lastQuestion, lastRole, lastOutputLanguage)
    }
}
