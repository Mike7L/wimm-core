import Foundation

/// Single source of truth for fallback model ids used by adapters when no
/// explicit model is configured.
public enum DefaultModels {
    public static let gemini = ModelSelection.defaultGeminiModel
    public static let openRouterTranscription = "openai/gpt-4o-mini"
}
