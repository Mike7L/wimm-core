import Foundation

public struct AnalyzeNoteCollectionUseCase: Sendable {
    private let storage: StoragePort
    private let answering: NoteCollectionAnsweringPort

    public init(storage: StoragePort, answering: NoteCollectionAnsweringPort) {
        self.storage = storage
        self.answering = answering
    }

    public func execute(
        noteIDs: [UUID],
        rawQuestion: String,
        role: String? = nil,
        outputLanguage: String? = nil
    ) async throws -> NoteCollectionAnswer {
        let normalizedQuestion = AskNoteQuestionUseCase.normalizeQuestion(rawQuestion)
        guard !normalizedQuestion.isEmpty else {
            throw NSError(
                domain: "AnalyzeNoteCollectionUseCase",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Question is empty after normalization"]
            )
        }

        let allNotes = try await storage.loadAll()
        let noteByID = Dictionary(uniqueKeysWithValues: allNotes.map { ($0.id, $0) })
        let resolvedNotes = try noteIDs.map { noteID in
            guard let note = noteByID[noteID] else {
                throw StorageError.noteNotFound(noteID.uuidString)
            }
            return note
        }

        let answer = try await answering.answer(
            question: normalizedQuestion,
            notes: resolvedNotes,
            role: role,
            outputLanguage: outputLanguage
        )

        return NoteCollectionAnswer(
            noteIDs: resolvedNotes.map(\.id),
            normalizedQuestion: normalizedQuestion,
            answer: answer,
            role: role,
            outputLanguage: outputLanguage
        )
    }
}