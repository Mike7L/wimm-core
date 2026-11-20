import Foundation

public struct ModelRoute: Sendable {
    public let model: String
    public let provider: LLMCfg.Provider

    public init(model: String, provider: LLMCfg.Provider) {
        self.model = model
        self.provider = provider
    }
}

public enum ModelRouter {
    public static func route(for rawModel: String, fallback: LLMCfg.Provider = .gemini) -> ModelRoute {
        let model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = model.lowercased()
        if lower.hasPrefix("models/") || lower.hasPrefix("gemini-") {
            return ModelRoute(model: model, provider: .gemini)
        }
        if model.contains("/"), !lower.hasPrefix("local/"), !lower.hasPrefix("apple/") {
            return ModelRoute(model: model, provider: .openrouter)
        }
        return ModelRoute(model: model, provider: fallback)
    }

    public static func provider(for rawModel: String, fallback: LLMCfg.Provider = .gemini) -> LLMCfg.Provider {
        route(for: rawModel, fallback: fallback).provider
    }
}
