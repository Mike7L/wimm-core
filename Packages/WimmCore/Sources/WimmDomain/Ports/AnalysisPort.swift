import Foundation

/// Порт для работы с LLM (Analysis).
/// Абстрагирует конкретного провайдера (Gemini / OpenAI).
public protocol AnalysisPort: Sendable {
    /// Проанализировать текст заметки и создать AnalysisCard.
    /// - Parameter text: Текст для анализа.
    /// - Returns: Структурированный результат.
    func analyze(text: String) async throws -> AnalysisCard

}

public protocol QuestionAnsweringPort: Sendable {
    func answer(
        question: String,
        note: CapturedNote,
        role: String?,
        outputLanguage: String?
    ) async throws -> String
}

public protocol NoteCollectionAnsweringPort: Sendable {
    func answer(
        question: String,
        notes: [CapturedNote],
        role: String?,
        outputLanguage: String?
    ) async throws -> String
}
