import Foundation

// Unified engine identifier used across UI and HUD (no string literals scattered).
public enum EngineID: String, Codable, CaseIterable, Sendable {
    case native
    case gemini
    case openrouter


    public var badgeText: String { rawValue.uppercased() }

    // Human-friendly label for UI
    public var label: String {
        switch self {
        case .gemini: return "Gemini"
        case .native: return "Native"
        case .openrouter: return "OpenRouter"

        }
    }

    // Tooltip/help text for UI
    public var help: String {
        switch self {
        case .gemini: return "Облачная транскрипция через Gemini (модели Gemini)" // TODO: локализация
        case .native: return "Локальная системная транскрипция (macOS 26+) с автоматическим fallback" // TODO: локализация
        case .openrouter: return "Облачная транскрипция через OpenRouter (универсальные модели)" // TODO: локализация

        }
    }
}
