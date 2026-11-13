import Foundation
import WimmDomain

public struct GeminiQuestionAnsweringAdapter: QuestionAnsweringPort, Sendable {
    private let apiKey: String
    private let modelName: String
    private let session: URLSession


    public init(apiKey: String, modelName: String = DefaultModels.gemini) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = URLSession.shared
    }

    public func answer(
        question: String,
        note: CapturedNote,
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        let noteTitle = note.card?.title ?? note.title ?? "Untitled"
        let noteSummary = note.card?.summary ?? ""
        let noteTags = note.card?.tags.joined(separator: ", ") ?? ""
        let noteProjects = note.card?.projects.joined(separator: ", ") ?? ""
        let roleInstruction: String
        if let role, !role.isEmpty {
            roleInstruction = "Adopt the `\(role)` style only as a presentation preference. Do not invent facts beyond the note."
        } else {
            roleInstruction = "Use a direct, grounded style."
        }

        let languageInstruction: String
        if let outputLanguage, !outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            languageInstruction = "Answer in \(outputLanguage)."
        } else {
            languageInstruction = "Answer in the same language as the question."
        }

        let prompt = """
        You answer questions about exactly one note.

        Rules:
        - Use only the provided note context.
        - Do not use external knowledge unless it is basic common language clarification.
        - If the note does not contain enough information, say so plainly.
        - Do not mention hidden reasoning, tools, or internal steps.
        - Prefer a concise answer.
        - \(roleInstruction)
        - \(languageInstruction)

        NOTE CONTEXT
        ID: \(note.id.uuidString)
        CreatedAt: \(note.createdAt)
        Title: \(noteTitle)
        Summary: \(noteSummary)
        Tags: \(noteTags)
        Projects: \(noteProjects)
        Text:
        \(note.text)

        QUESTION
        \(question)
        """

        return try await generateContent(prompt: prompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func generateContent(prompt: String) async throws -> String {
        try await GeminiTextGeneration(
            apiKey: apiKey,
            modelName: modelName,
            session: session,
            errorDomain: "GeminiQuestionAnsweringAdapter"
        )(prompt: prompt)
    }
}
