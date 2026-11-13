import Foundation
import WimmInfrastructure

/// Tool-free secretary editor. The host verifies and applies its unchanged JSON reply.
public struct GeminiPacketExecutor: SecretaryExecutor {
    public let name = "gemini"
    private let temperature: Double?
    private let maxOutputTokens: Int?
    public init(temperature: Double? = nil, maxOutputTokens: Int? = 65536) {
        self.temperature = temperature; self.maxOutputTokens = maxOutputTokens
    }

    public func run(_ request: SecretaryExecutionRequest,
                    onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard request.systemPrompt != nil, request.resumeSessionID == nil,
              let model = request.model, model.hasPrefix("gemini-"),
              model.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) }) else {
            throw SecretaryPacket.Failure("Gemini requires a tool-free packet and a valid explicit model.")
        }
        var req = try await LLMTransport.shared.makeGeminiRequest(model: model, timeout: request.timeout)
        var generation: [String: Any] = ["responseMimeType": "application/json"]
        if let temperature = ModelSampling.temperature(temperature, model: model) { generation["temperature"] = temperature }
        if let maxOutputTokens { generation["maxOutputTokens"] = maxOutputTokens }
        var body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": request.prompt]]]],
            "generationConfig": generation
        ]
        if let system = request.systemPrompt, !system.isEmpty { body["systemInstruction"] = ["parts": [["text": system]]] }
        let payload = try JSONSerialization.data(withJSONObject: body)
        req.httpBody = payload
        try payload.write(to: request.runDirectory.appendingPathComponent("request.json"), options: .atomic)
        // One call per attempt. Persist the complete response before interpreting it.
        let (data, response) = try await URLSession.shared.data(for: req)
        try data.write(to: request.runDirectory.appendingPathComponent("provider-response.json"), options: .atomic)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let usage = obj["usageMetadata"] as? [String: Any]
        let candidates = obj["candidates"] as? [[String: Any]] ?? []
        let candidate = candidates.first
        let content = candidate?["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        let finish = candidate?["finishReason"] as? String
        let ok = (200..<300).contains(status) && finish == "STOP" && !text.isEmpty
        return SecretaryExecution(exitStatus: ok ? 0 : 1, isError: !ok,
            finalText: text.isEmpty ? nil : text, costUSD: nil,
            tokensIn: usage?["promptTokenCount"] as? Int,
            tokensOut: usage?["candidatesTokenCount"] as? Int,
            turns: 1, model: model,
            error: ok ? nil : "Gemini HTTP \(status), finish \(finish ?? "unknown"); see provider-response.json")
    }
}
