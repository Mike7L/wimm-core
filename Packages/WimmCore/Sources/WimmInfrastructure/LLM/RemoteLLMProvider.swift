import Foundation

public struct GeminiModelProvider: ModelProvider {
    public let capability: ModelCapability
    public let identifier: String
    public let provider: LLMCfg.Provider = .gemini
    private let transport: LLMTransport

    public var metadata: [String: String] {
        [
            "provider": provider.rawValue,
            "model": identifier,
            "capability": capability.rawValue
        ]
    }

    public init(identifier: String, capability: ModelCapability, transport: LLMTransport = .shared) {
        self.identifier = identifier
        self.capability = capability
        self.transport = transport
    }

    public func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        try await performDetailed(request: request, tracer: tracer).text
    }

    public func performDetailed(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> ModelResponse {
        let allowedMimes: Set<String> = ["text/plain", "application/json", "application/xml", "application/yaml", "text/x.enum"]
        let safeMime = allowedMimes.contains(request.responseMimeType) ? request.responseMimeType : "text/plain"
        let maxRetries = Config.agentMaxRetries
        var attempt = 0
        while true {
            do {
                var httpRequest = try await transport.makeGeminiRequest(model: identifier, timeout: request.timeout, contentType: safeMime)
                let genCfg = GeminiRequest.GenConfig(
                    temperature: ModelSampling.temperature(request.temperature, model: identifier),
                    responseMimeType: safeMime,
                    responseSchema: request.schema.map { AnyEncodable($0) }
                )
                let body = GeminiRequest(
                    contents: [ .init(role: "user", parts: [.init(text: request.user)]) ],
                    generationConfig: genCfg,
                    systemInstruction: .init(role: "system", parts: [.init(text: request.system)])
                )
                httpRequest.httpBody = try JSONEncoder().encode(body)

                let (data, resp) = try await URLSession.shared.dataSafe(for: httpRequest)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    if let tracer { await MainActor.run { tracer("HTTP \(http.statusCode) error body:\n\(bodyText)") } }
                    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyText)"]
                    if let retryAfter = LLMRetryPolicy.retryAfterSeconds(from: http.value(forHTTPHeaderField: "Retry-After")) {
                        userInfo["RetryAfterSec"] = retryAfter
                    }
                    throw NSError(domain: ErrorDomain.badStatus, code: http.statusCode, userInfo: userInfo)
                }

                let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
                let text = decoded.firstCandidateText
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tracer { await MainActor.run { tracer("\(request.traceTag)\n\(trimmed)") } }
                if trimmed.isEmpty { throw NSError(domain: ErrorDomain.noText, code: 0) }
                return ModelResponse(text: trimmed, usage: decoded.usageMetadata?.tokenUsage)
            } catch {
                guard attempt < maxRetries, LLMRetryPolicy.shouldRetry(error: error) else {
                    let ns = error as NSError
                    var userInfo = ns.userInfo
                    userInfo["RetryAttempts"] = attempt
                    if let msg = userInfo[NSLocalizedDescriptionKey] as? String {
                        let lower = msg.lowercased()
                        if lower.contains("503") || lower.contains("unavailable") || lower.contains("overloaded") {
                            userInfo["FallbackReason"] = "temporary_unavailable"
                        }
                    }
                    throw NSError(domain: ns.domain, code: ns.code, userInfo: userInfo)
                }
                attempt += 1
                let delay = LLMRetryPolicy.delaySeconds(attempt: attempt, error: error)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

public struct OpenRouterModelProvider: ModelProvider {
    public let capability: ModelCapability
    public let identifier: String
    public let provider: LLMCfg.Provider = .openrouter
    private let transport: LLMTransport

    public var metadata: [String: String] {
        [
            "provider": provider.rawValue,
            "model": identifier,
            "capability": capability.rawValue
        ]
    }

    public init(identifier: String, capability: ModelCapability, transport: LLMTransport = .shared) {
        self.identifier = identifier
        self.capability = capability
        self.transport = transport
    }

    public func perform(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> String {
        try await performDetailed(request: request, tracer: tracer).text
    }

    public func performDetailed(request: ModelRequest, tracer: (@Sendable (String) -> Void)?) async throws -> ModelResponse {
        let maxRetries = Config.agentMaxRetries
        var attempt = 0
        while true {
            do {
                var httpRequest = try await transport.makeOpenRouterRequest(path: "chat/completions", timeout: request.timeout, tracer: tracer)
                let extra = transport.openRouterAttributionHeaders()
                let respFmt: OpenRouterRequest.ResponseFormat? = request.schema.map { s in
                    .init(type: "json_schema", json_schema: .init(name: "StructuredResponse", schema: AnyEncodable(s)))
                }
                let body = OpenRouterRequest(
                    model: identifier,
                    messages: [ .init(role: "system", content: request.system), .init(role: "user", content: request.user) ],
                    temperature: ModelSampling.temperature(request.temperature, model: identifier),
                    response_format: respFmt,
                    extra_headers: extra.isEmpty ? nil : extra
                )
                httpRequest.httpBody = try JSONEncoder().encode(body)

                let (data, resp) = try await URLSession.shared.dataSafe(for: httpRequest)
                if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    if let tracer { await MainActor.run { tracer("HTTP \(http.statusCode) error body:\n\(bodyText)") } }
                    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(bodyText)"]
                    if let retryAfter = LLMRetryPolicy.retryAfterSeconds(from: http.value(forHTTPHeaderField: "Retry-After")) {
                        userInfo["RetryAfterSec"] = retryAfter
                    }
                    throw NSError(domain: ErrorDomain.badStatus, code: http.statusCode, userInfo: userInfo)
                }

                let decoded = try JSONDecoder().decode(OpenRouterResponse.self, from: data)
                let text = decoded.choices.first?.message.content ?? ""
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tracer { await MainActor.run { tracer("\(request.traceTag)\n\(trimmed)") } }
                if trimmed.isEmpty { throw NSError(domain: ErrorDomain.noText, code: 0) }
                return ModelResponse(text: trimmed, usage: decoded.usage?.tokenUsage)
            } catch {
                guard attempt < maxRetries, LLMRetryPolicy.shouldRetry(error: error) else {
                    let ns = error as NSError
                    var userInfo = ns.userInfo
                    userInfo["RetryAttempts"] = attempt
                    if let msg = userInfo[NSLocalizedDescriptionKey] as? String {
                        let lower = msg.lowercased()
                        if lower.contains("503") || lower.contains("unavailable") || lower.contains("overloaded") {
                            userInfo["FallbackReason"] = "temporary_unavailable"
                        }
                    }
                    throw NSError(domain: ns.domain, code: ns.code, userInfo: userInfo)
                }
                attempt += 1
                let delay = LLMRetryPolicy.delaySeconds(attempt: attempt, error: error)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

public struct ModelProviderFactory {
    public static func create(capability: ModelCapability, identifier: String? = nil, transport: LLMTransport = .shared) -> ModelProvider {
        let modelId = identifier ?? ModelSelection.model(for: capability)
        let providerType = ModelRouter.provider(for: modelId)
        
        switch providerType {
        case .gemini:
            return GeminiModelProvider(identifier: modelId, capability: capability, transport: transport)
        case .openrouter:
            return OpenRouterModelProvider(identifier: modelId, capability: capability, transport: transport)
        case .apple:
            return AppleModelFactory.create(identifier: modelId, capability: capability)
        case .local:
#if ENABLE_LOCAL_AI
            guard LocalModelManager.isEnabled else {
                return DisabledLocalProvider(identifier: modelId, capability: capability)
            }
            if capability == .see {
                return LocalVisionProvider(identifier: modelId)
            }
            return LocalLLMProvider(identifier: modelId, capability: capability)
#else
            return DisabledLocalProvider(identifier: modelId, capability: capability)
#endif
        }
    }

}

// MARK: - Provider payloads

private struct GeminiRequest: Encodable {
    struct Part: Encodable { let text: String }
    struct Content: Encodable { let role: String; let parts: [Part] }
    let contents: [Content]
    let generationConfig: GenConfig?
    let systemInstruction: Content?
    struct GenConfig: Encodable { let temperature: Double?; let responseMimeType: String?; let responseSchema: AnyEncodable? }
}

private struct OpenRouterRequest: Encodable {
    struct Message: Encodable { let role: String; let content: String }
    let model: String
    let messages: [Message]
    let temperature: Double?
    let response_format: ResponseFormat?
    let extra_headers: [String: String]?
    struct ResponseFormat: Encodable {
        let type: String
        let json_schema: JSONSchema?
        struct JSONSchema: Encodable { let name: String; let schema: AnyEncodable }
    }
}

private struct OpenRouterResponse: Decodable {
    struct Choice: Decodable {
        struct Msg: Decodable { let role: String; let content: String }
        let message: Msg
    }
    let choices: [Choice]
    let usage: Usage?

    struct Usage: Decodable {
        struct PromptDetails: Decodable { let cached_tokens: Int? }
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let prompt_tokens_details: PromptDetails?

        var tokenUsage: TokenUsage {
            TokenUsage(
                inputTokens: prompt_tokens,
                outputTokens: completion_tokens,
                totalTokens: total_tokens,
                cachedInputTokens: prompt_tokens_details?.cached_tokens
            )
        }
    }
}
