import Foundation
import WimmInfrastructure

/// The same Terra model through the configured paid API when the CLI plan is exhausted.
/// The host still owns receipts, validation and all writes.
public struct TerraAPIExecutor: SecretaryExecutor {
    public let name = "openrouter"
    private let session: URLSession
    private let apiKey: String?
    public init(session: URLSession = .shared, apiKey: String? = nil) {
        self.session = session; self.apiKey = apiKey
    }

    public func run(_ request: SecretaryExecutionRequest,
                    onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard request.model == "openai/gpt-6.1-terra", request.systemPrompt != nil, request.resumeSessionID == nil else {
            throw SecretaryPacket.Failure("Terra API requires a complete tool-free packet and the exact Terra model.")
        }
        var req = try await LLMTransport.shared.makeOpenRouterRequest(path: "/chat/completions", timeout: request.timeout, apiKey: apiKey)
        let payload: [String: Any] = ["model": "openai/gpt-6.1-terra",
            "messages": [["role": "system", "content": request.systemPrompt!], ["role": "user", "content": request.prompt]],
            "reasoning": ["effort": request.effort ?? "medium"], "max_tokens": 65536,
            "response_format": ["type": "json_object"], "usage": ["include": true]]
        let body = try JSONSerialization.data(withJSONObject: payload)
        req.httpBody = body
        try body.write(to: request.runDirectory.appendingPathComponent("request.json"), options: .atomic)
        let (data, response) = try await session.data(for: req)
        try data.write(to: request.runDirectory.appendingPathComponent("provider-response.json"), options: .atomic)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let usage = obj["usage"] as? [String: Any]
        let choice = (obj["choices"] as? [[String: Any]])?.first
        let message = choice?["message"] as? [String: Any]
        let text = message?["content"] as? String
        let ok = (200..<300).contains(status) && choice?["finish_reason"] as? String == "stop" && text?.isEmpty == false
        return SecretaryExecution(exitStatus: ok ? 0 : 1, isError: !ok, finalText: text,
            costUSD: (usage?["cost"] as? NSNumber)?.doubleValue,
            tokensIn: usage?["prompt_tokens"] as? Int, tokensOut: usage?["completion_tokens"] as? Int,
            turns: 1, model: "openai/gpt-6.1-terra",
            error: ok ? nil : "Terra API HTTP \(status); see provider-response.json")
    }
}
