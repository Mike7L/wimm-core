import Foundation
import os

/// A multi-turn Gemini chat answered as a stream: text arrives in pieces as
/// the model writes it, so a voice can start on the first sentence while the
/// rest is still being generated. Built through `LLMTransport`, so private
/// mode refuses it (the conversation sends unmasked personal text), and logged
/// with its `tokens_*` usage like every other paid call.
public struct GeminiChatStream: Sendable {
    public struct Message: Sendable, Equatable {
        public enum Role: String, Sendable { case user, model }
        public let role: Role
        public var text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// A caller-owned, read-only capability. JSON strings keep provider payloads
    /// out of app actors; raw response parts (including thought signatures) stay here.
    public struct Tool: Sendable {
        public let name: String
        public let description: String
        public let parametersJSON: String
        public let call: @Sendable (String) async throws -> String

        public init(name: String, description: String, parametersJSON: String,
                    call: @escaping @Sendable (String) async throws -> String) {
            self.name = name; self.description = description
            self.parametersJSON = parametersJSON; self.call = call
        }
    }

    public let model: String
    private let operation: LLMOperation
    private let origin: String
    private let transport: LLMTransport
    private let session: URLSession

    public init(model: String, operation: LLMOperation, origin: String, transport: LLMTransport = .shared, session: URLSession = .shared) {
        self.model = model
        self.operation = operation
        self.origin = origin
        self.transport = transport
        self.session = session
    }

    /// Text pieces in order; finishing the stream means the answer is complete.
    /// `thinking` nil asks for the least thinking the model accepts.
    public func stream(
        system: String, messages: [Message], temperature: Double? = nil, timeout: TimeInterval = 90,
        thinking: Thinking? = nil, tools: [Tool] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, messages: messages, temperature: temperature,
                                  timeout: timeout, thinking: thinking ?? Self.acceptedThinking(model), tools: tools) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The whole answer at once, for a one-off preparation call.
    public func complete(system: String, messages: [Message], temperature: Double? = nil, timeout: TimeInterval = 240) async throws -> String {
        var text = ""
        for try await piece in stream(system: system, messages: messages, temperature: temperature, timeout: timeout) {
            text += piece
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A spoken reply has to start fast, and hidden reasoning is the main delay
    /// (a `gemini-flash-latest` turn thought for ~1,000–1,500 tokens, 12–23 s).
    /// Gemini 3 takes `thinkingLevel`, 2.5 takes `thinkingBudget`, and each
    /// rejects the other's field; an alias like `gemini-flash-latest` does not
    /// say which, so a 400 about thinking steps down to the next form.
    /// `lowLevel`/`mediumLevel` are for a caller who wants more thought; a
    /// model that rejects levels gets its own default instead.
    public enum Thinking: Sendable {
        case minimalLevel, zeroBudget, lowLevel, mediumLevel, modelDefault

        var config: [String: Any]? {
            switch self {
            case .minimalLevel: return ["thinkingLevel": "minimal"]
            case .zeroBudget: return ["thinkingBudget": 0]
            case .lowLevel: return ["thinkingLevel": "low"]
            case .mediumLevel: return ["thinkingLevel": "medium"]
            case .modelDefault: return nil
            }
        }

        var fallback: Thinking? {
            switch self {
            case .minimalLevel: return .zeroBudget
            case .zeroBudget, .lowLevel, .mediumLevel: return .modelDefault
            case .modelDefault: return nil
            }
        }

        /// Only the least-thinking chain is remembered per model.
        var isLeast: Bool { self == .minimalLevel || self == .zeroBudget }
    }

    /// The thinking form each model last accepted, so only its first call in a
    /// process pays the 400 round trip (in-memory; a relaunch learns it again).
    private static let accepted = OSAllocatedUnfairLock(initialState: [String: Thinking]())

    static func acceptedThinking(_ model: String) -> Thinking {
        accepted.withLock { $0[model] } ?? .minimalLevel
    }

    private func run(
        system: String, messages: [Message], temperature: Double?, timeout: TimeInterval,
        thinking: Thinking, tools: [Tool], yield: (String) -> Void
    ) async throws {
        var contents: [[String: Any]] = messages.map { ["role": $0.role.rawValue, "parts": [["text": $0.text]]] }
        let lastUser = messages.last(where: { $0.role == .user })?.text ?? ""
        let deadline = Date().addingTimeInterval(timeout)
        var calls = 0
        var nextThinking = thinking
        for _ in 0..<8 {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw URLError(.timedOut) }
            let result = try await round(system: system, contents: contents, lastUser: lastUser,
                                         temperature: temperature, timeout: remaining,
                                         thinking: nextThinking, tools: tools, yield: yield)
            // Keep both the caller's explicit level and any provider fallback
            // for the entire exchange, including every tool continuation.
            nextThinking = result.thinking
            let parts = result.parts
            let requested = parts.compactMap { $0["functionCall"] as? [String: Any] }
            guard !requested.isEmpty else { return }
            calls += requested.count
            guard calls <= 16 else { throw Self.toolLimitError }
            contents.append(["role": "model", "parts": parts])
            var responses: [[String: Any]] = []
            for call in requested {
                try Task.checkCancellation()
                guard let name = call["name"] as? String,
                      let tool = tools.first(where: { $0.name == name }) else {
                    throw NSError(domain: "GeminiChatStream", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Модель запросила недоступный инструмент чтения."])
                }
                let args = try JSONSerialization.data(withJSONObject: call["args"] as? [String: Any] ?? [:])
                let result = try await tool.call(String(decoding: args, as: UTF8.self))
                try Task.checkCancellation()
                // The transport checks again before the next cloud request.
                try PrivateMode.checkCloudEgress(provider: "gemini")
                var response: [String: Any] = ["name": name, "response": ["result": result]]
                if let id = call["id"] as? String { response["id"] = id }
                responses.append(["functionResponse": response])
            }
            contents.append(["role": "user", "parts": responses])
        }
        throw Self.toolLimitError
    }

    private static var toolLimitError: NSError {
        NSError(domain: "GeminiChatStream", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Достигнут предел чтения контекста. Уточни вопрос."])
    }

    private struct RoundResult {
        let parts: [[String: Any]]
        let thinking: Thinking
    }

    private func round(
        system: String, contents: [[String: Any]], lastUser: String, temperature: Double?, timeout: TimeInterval,
        thinking: Thinking, tools: [Tool], yield: (String) -> Void
    ) async throws -> RoundResult {
        var request = try await transport.makeGeminiRequest(model: model, timeout: timeout, endpoint: "streamGenerateContent")
        if var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "alt", value: "sse")]
            request.url = components.url
        }
        var generation: [String: Any] = [:]
        if let temperature = ModelSampling.temperature(temperature, model: model) { generation["temperature"] = temperature }
        if let config = thinking.config { generation["thinkingConfig"] = config }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": generation,
        ]
        if !tools.isEmpty {
            body["tools"] = [["functionDeclarations": try tools.map { tool in
                ["name": tool.name, "description": tool.description,
                 "parameters": try JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8))] as [String: Any]
            }]]
        }
        try Task.checkCancellation()
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let loggedUser = tools.isEmpty ? lastUser : String(decoding: try JSONSerialization.data(withJSONObject: contents), as: UTF8.self)
        let cid = LLMLogger.shared.logRequest(model: model, provider: "gemini", origin: origin,
                                              attributes: ["operation": operation.rawValue],
                                              system: system, user: loggedUser, isStreaming: true)
        let started = Date()
        var firstPiece: Date?
        var answer = ""
        var parts: [[String: Any]] = []
        var usage: TokenUsage?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines { body += line + "\n" }
                if let fallback = thinking.fallback, http.statusCode == 400, body.localizedCaseInsensitiveContains("thinking") {
                    LLMLogger.shared.logResponse(model: model, provider: "gemini", origin: origin,
                                                 attributes: ["operation": operation.rawValue], system: system, user: loggedUser,
                                                 response: nil, error: "HTTP 400 (\(thinking) not accepted)", isStreaming: true, correlationId: cid)
                    if thinking.isLeast { Self.accepted.withLock { $0[model] = fallback } }
                    return try await round(system: system, contents: contents, lastUser: lastUser, temperature: temperature,
                                           timeout: timeout, thinking: fallback, tools: tools, yield: yield)
                }
                throw NSError(domain: ErrorDomain.badStatus, code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "Gemini HTTP \(http.statusCode): \(body.prefix(400))"])
            }
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = Data(line.dropFirst(5).utf8)
                guard let chunk = try? JSONDecoder().decode(GeminiResponse.self, from: payload) else { continue }
                if let metered = chunk.usageMetadata?.tokenUsage, !metered.isEmpty { usage = metered }
                try Task.checkCancellation()
                let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
                let candidates = raw?["candidates"] as? [[String: Any]]
                let content = candidates?.first?["content"] as? [String: Any]
                let incoming = content?["parts"] as? [[String: Any]] ?? []
                parts += incoming // Preserve every part and its thoughtSignature verbatim.
                let piece = incoming.filter { $0["thought"] as? Bool != true }
                    .compactMap { $0["text"] as? String }.joined()
                guard !piece.isEmpty else { continue }
                if firstPiece == nil { firstPiece = Date() }
                answer += piece
                yield(piece)
            }
        } catch {
            // A cancelled turn was still paid for up to here; its usage is unknown, not zero.
            LLMLogger.shared.logResponse(model: model, provider: "gemini", origin: origin,
                                         attributes: ["operation": operation.rawValue], system: system, user: loggedUser,
                                         response: answer.isEmpty ? nil : answer, error: error.localizedDescription,
                                         isStreaming: true, correlationId: cid)
            throw error
        }
        var attributes = ["tool_calls": String(parts.filter { $0["functionCall"] != nil }.count), "operation": operation.rawValue, "thinking": "\(thinking)",
                          "total_ms": String(Int(Date().timeIntervalSince(started) * 1000))]
        // Time to the first text is what a listener waits for.
        if let firstPiece { attributes["first_text_ms"] = String(Int(firstPiece.timeIntervalSince(started) * 1000)) }
        if let usage { attributes.merge(usage.logAttributes) { _, new in new } }
        LLMLogger.shared.logResponse(model: model, provider: "gemini", origin: origin, attributes: attributes,
                                     system: system, user: loggedUser, response: answer, isStreaming: true, correlationId: cid)
        return RoundResult(parts: parts, thinking: thinking)
    }
}
