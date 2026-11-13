import Foundation
import WimmDomain

public struct GeminiNoteCollectionAnsweringAdapter: NoteCollectionAnsweringPort, Sendable {
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
        notes: [CapturedNote],
        role: String?,
        outputLanguage: String?
    ) async throws -> String {
        let roleInstruction: String
        if let role, !role.isEmpty {
            roleInstruction = "Adopt the `\(role)` style only as a presentation preference. Do not invent facts beyond the provided notes."
        } else {
            roleInstruction = "Use a direct, grounded style."
        }

        let languageInstruction: String
        if let outputLanguage, !outputLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            languageInstruction = "Answer in \(outputLanguage)."
        } else {
            languageInstruction = "Answer in the same language as the question."
        }

        let notesBlock = notes.enumerated().map { index, note in
            let noteTitle = note.card?.title ?? note.title ?? "Untitled"
            let noteSummary = note.card?.summary ?? ""
            let noteTags = note.card?.tags.joined(separator: ", ") ?? ""
            let noteProjects = note.card?.projects.joined(separator: ", ") ?? ""
            return """
            NOTE \(index + 1)
            ID: \(note.id.uuidString)
            CreatedAt: \(note.createdAt)
            Title: \(noteTitle)
            Summary: \(noteSummary)
            Tags: \(noteTags)
            Projects: \(noteProjects)
            Text:
            \(note.text)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        You answer questions about exactly the provided notes.

        Rules:
        - Use only the provided note context.
        - Do not use external knowledge unless it is basic common language clarification.
        - If the notes do not contain enough information, say so plainly.
        - Synthesize across notes when useful, but do not invent missing evidence.
        - Do not mention hidden reasoning, tools, or internal steps.
        - Prefer a concise answer.
        - \(roleInstruction)
        - \(languageInstruction)

        NOTES
        \(notesBlock)

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
            errorDomain: "GeminiNoteCollectionAnsweringAdapter"
        )(prompt: prompt)
    }
}
