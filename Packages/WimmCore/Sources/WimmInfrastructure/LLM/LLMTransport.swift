import Foundation

/// Shared factory for provider-specific URLRequests used by LLM calls.
/// Centralizes API key handling, sanitization, and common headers so callers
/// can focus on payload construction and response parsing.
open class LLMTransport {
    public static let shared = LLMTransport()

    private let geminiRotator: APIKeyRotator
    private let openRouterRotator: OpenRouterKeyRotator

    public init(geminiRotator: APIKeyRotator = .shared, openRouterRotator: OpenRouterKeyRotator = .shared) {
        self.geminiRotator = geminiRotator
        self.openRouterRotator = openRouterRotator
    }

    /// Build a POST request for the Gemini generateContent endpoint with the given model.
    /// The returned request has the API key embedded as a query item and `Content-Type`
    /// preconfigured. Callers should assign the HTTP body before execution.
    public func makeGeminiRequest(model: String, timeout: TimeInterval, contentType: String = "application/json", apiKey: String? = nil, endpoint: String = "generateContent") async throws -> URLRequest {
        try PrivateMode.checkCloudEgress(provider: "gemini")
        let rawKey: String
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawKey = apiKey
        } else {
            rawKey = await geminiRotator.currentKey()
        }
        let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw NSError(domain: ErrorDomain.badStatus, code: 401, userInfo: [NSLocalizedDescriptionKey: "No Gemini API key configured", "Provider": "gemini"])
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(endpoint)?key=\(trimmedKey)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return req
    }

    /// Build a POST request for an OpenRouter endpoint (e.g. `chat/completions`, `responses`).
    /// Automatically injects the bearer token, standard attribution headers, and optional extras.
    public func makeOpenRouterRequest(
        path: String,
        timeout: TimeInterval,
        contentType: String = "application/json",
        extraHeaders: [String: String] = [:],
        tracer: (@Sendable (String) -> Void)? = nil,
        apiKey: String? = nil
    ) async throws -> URLRequest {
        try PrivateMode.checkCloudEgress(provider: "openrouter")
        let totalKeys = await openRouterRotator.count()
        let rawKey: String
        if let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawKey = apiKey
        } else {
            rawKey = await openRouterRotator.currentKey()
        }
        let sanitized = sanitizeOpenRouterKey(rawKey)

        guard !sanitized.isEmpty else {
            throw NSError(domain: ErrorDomain.badStatus, code: 401, userInfo: [NSLocalizedDescriptionKey: "No OpenRouter API key configured", "Provider": "openrouter"])
        }

        if let tracer {
            await MainActor.run {
                let preview = sanitized.prefix(6)
                tracer("OpenRouter keys configured: \(totalKeys) current_prefix=\(String(preview))")
            }
        }

        let urlString = "https://openrouter.ai/api/v1/\(path)"
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(sanitized)", forHTTPHeaderField: "Authorization")

        for (k, v) in attributionHeaders() { req.setValue(v, forHTTPHeaderField: k) }
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        return req
    }

    /// Expose the attribution headers so callers can include them in payloads when required by the API.
    public func openRouterAttributionHeaders() -> [String: String] {
        attributionHeaders()
    }

    private func sanitizeOpenRouterKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private func attributionHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        let env = ProcessInfo.processInfo.environment
        if let ref = env["OPENROUTER_HTTP_REFERER"], !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["HTTP-Referer"] = ref
        }
        if let title = env["OPENROUTER_X_TITLE"], !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["X-Title"] = title
        }
        return headers
    }
}

extension LLMTransport: @unchecked Sendable {}
