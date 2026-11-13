import Foundation

/// Single source of truth for fallback model ids used by adapters when no
/// explicit model is configured.
public enum DefaultModels {
    public static let gemini = "gemini-3.5-flash"
    public static let openRouterTranscription = "openai/gpt-4o-mini"
}
