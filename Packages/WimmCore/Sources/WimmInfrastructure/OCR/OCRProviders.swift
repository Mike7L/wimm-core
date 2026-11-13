import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Vision

public struct VisionOCRProvider: OCRProvider {
    public init() {}

    public func performOCR(on image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try await VisionDocumentAndSceneExtractor.extract(from: image)
        }.value
    }
}

// MARK: - Gemini

public struct GeminiOCRProvider: OCRProvider {
    private let model: String
    private let transport: LLMTransport

    public init(model: String, transport: LLMTransport) {
        self.model = model
        self.transport = transport
    }

    public func performOCR(on image: CGImage) async throws -> String {
        guard let png = image.pngData() else { return "" }

        let prompt = PromptLoader.load("ocr_image_extraction")
        let request = GeminiOCRRequest(
            contents: [
                .init(
                    role: "user",
                    parts: [
                        .init(text: prompt),
                        .init(
                            inlineData: .init(
                                mimeType: "image/png", data: png.base64EncodedString())),
                    ])
            ],
            generationConfig: .init(temperature: ModelSampling.temperature(0.0, model: model), maxOutputTokens: 8192)
        )

        let payload = try JSONEncoder().encode(request)
        var httpRequest = try await transport.makeGeminiRequest(
            model: model, timeout: LLMCfg.requestTimeout)
        httpRequest.httpBody = payload

        let origin = "GeminiOCRProvider.performOCR"
        let cid = LLMLogger.shared.logRequest(
            model: model, provider: "gemini", origin: origin, system: "OCR Request",
            user: "Extract text from image", isStreaming: false)

        do {
            let (data, response) = try await URLSession.shared.data(for: httpRequest)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(data: data, encoding: .utf8) ?? ""
                let error = "Gemini OCR failed (HTTP \(http.statusCode)): \(snippet)"
                LLMLogger.shared.logResponse(
                    model: model, provider: "gemini", origin: origin, system: "OCR Request",
                    user: "Extract text from image", response: nil, error: error,
                    isStreaming: false, correlationId: cid)
                throw NSError(
                    domain: ErrorDomain.badStatus,
                    code: http.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Gemini OCR failed (HTTP \(http.statusCode))",
                        "GStatus": "\(http.statusCode)",
                        "GBody": snippet,
                    ]
                )
            }

            let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
            let trimmed = decoded.firstCandidateText.trimmingCharacters(in: .whitespacesAndNewlines)

            var attrs = ["operation": LLMOperation.ocr.rawValue]
            if let usage = decoded.usageMetadata?.tokenUsage, !usage.isEmpty {
                attrs.merge(usage.logAttributes) { _, new in new }
            }
            LLMLogger.shared.logResponse(
                model: model, provider: "gemini", origin: origin, attributes: attrs,
                system: "OCR Request", user: "Extract text from image", response: trimmed,
                isStreaming: false, correlationId: cid)
            return trimmed
        } catch {
            LLMLogger.shared.logResponse(
                model: model, provider: "gemini", origin: origin, system: "OCR Request",
                user: "Extract text from image", response: nil, error: error.localizedDescription,
                isStreaming: false, correlationId: cid)
            throw error
        }
    }
}

// MARK: - OpenRouter

public struct OpenRouterOCRProvider: OCRProvider {
    private let model: String
    private let transport: LLMTransport

    public init(model: String, transport: LLMTransport) {
        self.model = model
        self.transport = transport
    }

    public func performOCR(on image: CGImage) async throws -> String {
        guard let png = image.pngData() else { return "" }

        let prompt = PromptLoader.load("ocr_image_extraction")
        let request = OpenRouterOCRRequest(
            model: model,
            messages: [
                .init(
                    role: "user",
                    content: [
                        .init(type: "text", text: prompt, imageURL: nil),
                        .init(
                            type: "image_url", text: nil,
                            imageURL: .init(
                                url: "data:image/png;base64,\(png.base64EncodedString())")),
                    ])
            ],
            temperature: ModelSampling.temperature(0.0, model: model)
        )

        let payload = try JSONEncoder().encode(request)
        var httpRequest = try await transport.makeOpenRouterRequest(
            path: "chat/completions", timeout: LLMCfg.requestTimeout)
        httpRequest.httpBody = payload

        let origin = "OpenRouterOCRProvider.performOCR"
        let cid = LLMLogger.shared.logRequest(
            model: model, provider: "openrouter", origin: origin, system: "OCR Request",
            user: "Extract text from image (Vision)", isStreaming: false)

        do {
            let (data, response) = try await URLSession.shared.data(for: httpRequest)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }

            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(data: data, encoding: .utf8) ?? ""
                let error = "OpenRouter OCR failed (HTTP \(http.statusCode)): \(snippet)"
                LLMLogger.shared.logResponse(
                    model: model, provider: "openrouter", origin: origin, system: "OCR Request",
                    user: "Extract text from image (Vision)", response: nil, error: error,
                    isStreaming: false, correlationId: cid)
                throw NSError(
                    domain: ErrorDomain.badStatus,
                    code: http.statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "OpenRouter OCR failed (HTTP \(http.statusCode))",
                        "GStatus": "\(http.statusCode)",
                        "GBody": snippet,
                    ]
                )
            }

            let decoded = try JSONDecoder().decode(OpenRouterOCRResponse.self, from: data)
            let text = decoded.choices?.first?.message?.content ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            LLMLogger.shared.logResponse(
                model: model, provider: "openrouter", origin: origin, system: "OCR Request",
                user: "Extract text from image (Vision)", response: trimmed, isStreaming: false,
                correlationId: cid)
            return trimmed
        } catch {
            LLMLogger.shared.logResponse(
                model: model, provider: "openrouter", origin: origin, system: "OCR Request",
                user: "Extract text from image (Vision)", response: nil,
                error: error.localizedDescription, isStreaming: false, correlationId: cid)
            throw error
        }
    }
}

// MARK: - Private Structs

private struct GeminiOCRRequest: Encodable {
    struct InlineData: Encodable {
        let mimeType: String
        let data: String
    }

    struct Part: Encodable {
        let text: String?
        let inlineData: InlineData?

        init(text: String) {
            self.text = text
            self.inlineData = nil
        }

        init(inlineData: InlineData) {
            self.text = nil
            self.inlineData = inlineData
        }
    }

    struct Content: Encodable {
        let role: String
        let parts: [Part]
    }

    struct GenerationConfig: Encodable {
        let temperature: Double?
        let maxOutputTokens: Int?
    }

    let contents: [Content]
    let generationConfig: GenerationConfig?
}

private struct OpenRouterOCRRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [ContentPart]
    }

    struct ContentPart: Encodable {
        let type: String
        let text: String?
        let imageURL: ImageURL?

        enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }
    }

    struct ImageURL: Encodable {
        let url: String
    }

    let model: String
    let messages: [Message]
    let temperature: Double?
}

private struct OpenRouterOCRResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }
        let message: Message?
    }
    let choices: [Choice]?
}

// MARK: - Extensions

extension CGImage {
    fileprivate func pngData() -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(dest, self, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
