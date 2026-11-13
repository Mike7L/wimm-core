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
        if model.hasPrefix("apple/") || model == "apple" {
            return ModelRoute(model: model, provider: .apple)
        }
        if model.hasPrefix("local/") {
            return ModelRoute(model: model, provider: .local)
        }
        if model.hasPrefix("models/") || model.lowercased().hasPrefix("gemini-") {
            return ModelRoute(model: model, provider: .gemini)
        }
        if model.contains("/") {
            return ModelRoute(model: model, provider: .openrouter)
        }
        return ModelRoute(model: model, provider: fallback)
    }

    public static func provider(for rawModel: String, fallback: LLMCfg.Provider = .gemini) -> LLMCfg.Provider {
        route(for: rawModel, fallback: fallback).provider
    }
}
