import Foundation

// Public model type for OpenRouter models list
public struct OpenRouterModel: Identifiable, Decodable, Equatable, Sendable {
    public let id: String
    public let name: String?
    public let modelDescription: String?
    public let isAudioCapable: Bool?
}

// Internal DTO matching OpenRouter models API shape (subset)
private struct ORModelsEnvelope: Decodable { let data: [ORModelDTO] }
private struct ORModelDTO: Decodable {
    let id: String
    let name: String?
    let description: String?
}

// Lightweight cache + fetcher
public actor OpenRouterModelsAPI {
    public static let shared = OpenRouterModelsAPI()
    private var cached: [OpenRouterModel] = []
    private var lastFetch: Date? = nil
    private let ttl: TimeInterval = 10 * 60 // 10 minutes

    public static func fetch(forceReload: Bool = false) async throws -> [OpenRouterModel] {
        return try await shared.fetchInternal(forceReload: forceReload)
    }

    private func shouldUseCache(force: Bool) -> Bool {
        if force { return false }
        guard let t = lastFetch else { return false }
        return Date().timeIntervalSince(t) < ttl && !cached.isEmpty
    }

    private func mark(models: [OpenRouterModel]) {
        self.cached = models
        self.lastFetch = Date()
    }

    private func fetchInternal(forceReload: Bool) async throws -> [OpenRouterModel] {
        if shouldUseCache(force: forceReload) { return cached }

        let url = URL(string: "https://openrouter.ai/api/v1/models")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Try to include Authorization if configured to avoid rate limits on the public endpoint
        let rawKey = await OpenRouterKeyRotator.shared.currentKey()
        let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && !trimmed.lowercased().contains("replace_with_openrouter_key") {
            req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw NSError(domain: ErrorDomain.badStatus, code: code, userInfo: [NSLocalizedDescriptionKey: body])
        }
        let decoded = try JSONDecoder().decode(ORModelsEnvelope.self, from: data)
        let mapped: [OpenRouterModel] = decoded.data.map { dto in
            let lower = dto.id.lowercased()
            // Mark as audio-capable for models that clearly indicate audio or multimodal audio support.
            // Avoid flagging gpt-4o-mini which often lacks input_audio on OpenRouter.
            let isGpt4oNonMini = (lower.contains("/gpt-4o") || lower.contains("gpt-4o")) && !lower.contains("gpt-4o-mini")
            let audioHeuristic = (
                lower.contains("omni") ||
                lower.contains("whisper") ||
                lower.contains("-audio") ||
                isGpt4oNonMini
            )
            return OpenRouterModel(id: dto.id, name: dto.name, modelDescription: dto.description, isAudioCapable: audioHeuristic ? true : nil)
        }
        mark(models: mapped)
        return mapped
    }
}
