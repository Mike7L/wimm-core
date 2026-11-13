import Foundation

public struct AskNoteQuestionUseCase: Sendable {
    private let readNote: ReadNoteUseCase
    private let answering: QuestionAnsweringPort

    public init(storage: StoragePort, answering: QuestionAnsweringPort) {
        self.readNote = ReadNoteUseCase(storage: storage)
        self.answering = answering
    }

    public func execute(
        noteID: UUID,
        rawQuestion: String,
        role: String? = nil,
        outputLanguage: String? = nil
    ) async throws -> NoteQuestionAnswer {
        guard let note = try await readNote.execute(id: noteID) else {
            throw StorageError.noteNotFound(noteID.uuidString)
        }

        let normalizedQuestion = Self.normalizeQuestion(rawQuestion)
        guard !normalizedQuestion.isEmpty else {
            throw NSError(
                domain: "AskNoteQuestionUseCase",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Question is empty after normalization"]
            )
        }

        let answer = try await answering.answer(
            question: normalizedQuestion,
            note: note,
            role: role,
            outputLanguage: outputLanguage
        )

        return NoteQuestionAnswer(
            noteID: note.id,
            normalizedQuestion: normalizedQuestion,
            answer: answer,
            role: role,
            outputLanguage: outputLanguage
        )
    }

    public static func normalizeQuestion(_ rawQuestion: String) -> String {
        var value = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        var didStrip = true
        while didStrip {
            didStrip = false

            let prefixes = ["ответ на вопрос", "вопрос"]
            for prefix in prefixes {
                if value.lowercased().hasPrefix(prefix) {
                    value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    value = stripLeadingPunctuation(value)
                    didStrip = true
                }
            }
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLeadingPunctuation(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let punctuation = CharacterSet(charactersIn: ".:,-—–;!? ")

        while let first = value.unicodeScalars.first, punctuation.contains(first) {
            value = String(value.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value
    }
}