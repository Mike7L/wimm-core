import Foundation
import WimmDomain

public actor GeminiAdapter: AnalysisPort {
    private let apiKey: String
    private let modelName: String
    private let session: URLSession

    private static let jsonDecoder = JSONDecoder()


    public init(apiKey: String, modelName: String = DefaultModels.gemini) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = URLSession.shared
    }

    public func analyze(text: String) async throws -> AnalysisCard {
        let prompt = """
            You are an expert analyst. Analyze the following voice note text and return ONLY a JSON object (no markdown) with these fields:
            - title: A concise title (string).
            - summary: A short summary of 2-3 sentences (string).
            - tags: Array of relevant keyword tags (array of strings).
            - projects: Array of inferred project or topic names (array of strings).
            - is_artifact: true if this is a concrete deliverable or finished output (boolean).
            - is_draft: true if the content is clearly a work-in-progress (boolean).
            - is_insight: true if this captures a key realization or learning (boolean).
            - is_liked: false (boolean, user sets this manually).

            Text:
            \(text)
            """

        let response = try await generateContent(prompt: prompt)
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(
                domain: "GeminiAdapter", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string"])
        }

        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return card(from: dict)
        }
        return try Self.jsonDecoder.decode(AnalysisCard.self, from: data)
    }


    private func card(from dictionary: [String: Any]) -> AnalysisCard {
        AnalysisCard(
            title: dictionary["title"] as? String ?? "Untitled",
            summary: dictionary["summary"] as? String ?? "",
            tags: dictionary["tags"] as? [String] ?? [],
            projects: dictionary["projects"] as? [String] ?? [],
            isArtifact: bool(from: dictionary, snake: "is_artifact", camel: "isArtifact"),
            isDraft: bool(from: dictionary, snake: "is_draft", camel: "isDraft"),
            isInsight: bool(from: dictionary, snake: "is_insight", camel: "isInsight"),
            isLiked: bool(from: dictionary, snake: "is_liked", camel: "isLiked")
        )
    }

    private func generateContent(prompt: String) async throws -> String {
        try await GeminiTextGeneration(
            apiKey: apiKey,
            modelName: modelName,
            session: session,
            errorDomain: "GeminiAdapter"
        )(prompt: prompt)
    }

    private func extractJSON(from text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[firstNewline...])
            } else {
                cleaned = String(cleaned.dropFirst(3))
            }
            if cleaned.hasSuffix("```") { cleaned = String(cleaned.dropLast(3)) }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let first = cleaned.firstIndex(of: "{"),
              let last = cleaned.lastIndex(of: "}"), first <= last
        else { return cleaned }
        return String(cleaned[first...last])
    }

    private func bool(from dictionary: [String: Any], snake: String, camel: String) -> Bool {
        dictionary[snake] as? Bool ?? dictionary[camel] as? Bool ?? false
    }
}
