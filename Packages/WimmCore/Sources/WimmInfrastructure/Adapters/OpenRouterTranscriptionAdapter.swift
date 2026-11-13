import Foundation
import WimmDomain

public struct OpenRouterTranscriptionAdapter: TranscriptionPort, Sendable {
    private let apiKey: String
    private let modelName: String
    private let session: URLSession

    public init(apiKey: String, modelName: String = DefaultModels.openRouterTranscription) {
        self.apiKey = apiKey
        self.modelName = modelName
        self.session = URLSession.shared
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        throw NSError(domain: "OpenRouterTranscriptionAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Streaming capture is not supported with OpenRouter REST API."])
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        throw NSError(domain: "OpenRouterTranscriptionAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Capture stop is not supported with OpenRouter REST API."])
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        try PrivateMode.refuseCloudAudio(provider: "openrouter")
        let data = try Data(contentsOf: fileURL)
        let b64 = data.base64EncodedString()
        let format = audioFormat(for: fileURL.pathExtension.lowercased())

        guard let url = URL(string: "https://openrouter.ai/api/v1/responses") else {
            throw NSError(domain: "OpenRouterTranscriptionAdapter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid OpenRouter URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": modelName,
            "input": [
                [
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": PromptLoader.load("transcription_standard_prompt", variables: ["lang_hint": ""])],
                        ["type": "input_audio", "input_audio": ["data": b64, "format": format]],
                    ],
                ]
            ],
            "instructions": PromptLoader.load("transcription_system_prompt"),
        ]
        if let temperature = ModelSampling.temperature(0.0, model: modelName) { body["temperature"] = temperature }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (respData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenRouterTranscriptionAdapter", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let err = String(data: respData, encoding: .utf8) ?? "Unknown OpenRouter error"
            throw NSError(domain: "OpenRouterTranscriptionAdapter", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: err])
        }

        let text = extractText(from: respData).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw NSError(domain: "OpenRouterTranscriptionAdapter", code: 204, userInfo: [NSLocalizedDescriptionKey: "OpenRouter returned empty transcription"])
        }
        return text
    }

    private func audioFormat(for ext: String) -> String {
        switch ext {
        case "m4a": return "m4a"
        case "mp4": return "mp4"
        case "aac": return "aac"
        case "wav": return "wav"
        case "mp3": return "mp3"
        case "caf": return "wav"
        default: return "wav"
        }
    }

    private func extractText(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }

        if let output = json["output"] as? [[String: Any]] {
            for message in output {
                if let content = message["content"] as? [[String: Any]] {
                    let parts = content.compactMap { $0["text"] as? String }
                    let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !joined.isEmpty { return joined }
                }
            }
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let content = message["content"] as? String, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return content
            }
            if let content = message["content"] as? [[String: Any]] {
                let parts = content.compactMap { $0["text"] as? String }
                let joined = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty { return joined }
            }
        }

        return ""
    }
}
