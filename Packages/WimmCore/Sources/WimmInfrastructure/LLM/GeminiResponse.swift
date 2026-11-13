import Foundation

/// The `generateContent` response envelope — one decoder for every Gemini call
/// in the codebase.
///
/// There used to be six near-identical copies of this shape (the analysis,
/// question-answering, note-collection and transcription adapters, the OCR
/// provider, and the metered remote provider), and they disagreed about which
/// fields were optional. The most tolerant spelling wins here: Gemini omits
/// `content` on a safety block and omits `text` on a non-text part, and a
/// stricter decoder turns either into a decode failure that reads like a
/// network error.
///
/// `usageMetadata` is load-bearing for cost accounting — see AGENTS.md on the
/// `tokens_*` keys — so it stays on the shared type rather than living only on
/// the paths that happen to meter today.
struct GeminiResponse: Decodable {
    struct Cand: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }

    let candidates: [Cand]?
    let usageMetadata: UsageMetadata?

    /// All text parts of the first candidate, joined. Empty when the model
    /// returned nothing usable — callers decide whether that is an error.
    var firstCandidateText: String {
        candidates?.first?.content?.parts?
            .compactMap(\.text)
            .joined(separator: " ") ?? ""
    }

    /// Gemini's counters. `promptTokensDetails` splits the prompt by modality —
    /// that is where audio shows up, and audio is priced apart from text.
    /// `thoughtsTokenCount` is the hidden reasoning, billed as output but not
    /// included in `candidatesTokenCount`.
    struct UsageMetadata: Decodable {
        struct ModalityCount: Decodable {
            let modality: String?
            let tokenCount: Int?
        }
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
        let cachedContentTokenCount: Int?
        let thoughtsTokenCount: Int?
        let promptTokensDetails: [ModalityCount]?

        var tokenUsage: TokenUsage {
            let audio = promptTokensDetails?
                .filter { $0.modality?.uppercased() == "AUDIO" }
                .compactMap(\.tokenCount)
                .reduce(0, +)
            return TokenUsage(
                inputTokens: promptTokenCount,
                outputTokens: candidatesTokenCount,
                totalTokens: totalTokenCount,
                cachedInputTokens: cachedContentTokenCount,
                audioTokens: (audio ?? 0) > 0 ? audio : nil,
                thoughtsTokens: thoughtsTokenCount
            )
        }
    }
}

/// The plain text-in / text-out `generateContent` call.
///
/// Three adapters had a byte-for-byte copy of this method — same URL string,
/// same one-part body, same status check, same envelope decode — differing only
/// in the `NSError` domain they raised. Callers that need a richer body (inline
/// audio, images, a `generationConfig`) still build their own request; they
/// share the envelope above, not this helper.
struct GeminiTextGeneration {
    let apiKey: String
    let modelName: String
    let session: URLSession
    /// Kept per-caller so an error still says which adapter failed.
    let errorDomain: String

    init(
        apiKey: String,
        modelName: String,
        session: URLSession = .shared,
        errorDomain: String
    ) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = session
        self.errorDomain = errorDomain
    }

    func callAsFunction(prompt: String) async throws -> String {
        // Builds its own URL instead of going through LLMTransport, so it needs
        // the same private-mode guard: these prompts carry unmasked note text.
        try PrivateMode.checkCloudEgress(provider: "gemini")
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)"
        ) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]]
        ])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: errorDomain,
                code: (response as? HTTPURLResponse)?.statusCode ?? 500,
                userInfo: [NSLocalizedDescriptionKey: errorText]
            )
        }

        return try JSONDecoder().decode(GeminiResponse.self, from: data).firstCandidateText
    }
}
