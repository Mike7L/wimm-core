import Foundation

public enum DocumentOCREngine: String, CaseIterable, Identifiable, Sendable {
    case vision
    case mlx
    case gemini
    case miniCPM = "minicpm"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .vision: return "Vision"
        case .mlx: return "Vision + MLX photos"
        case .gemini: return "Gemini"
        case .miniCPM: return "MiniCPM-V"
        }
    }
}

public enum DocumentOCRConfig {
    public static var engine: DocumentOCREngine { Config.documentOcrEngine }
    public static var geminiModel: String { Config.documentOcrGeminiModel }
    public static var openRouterModel: String { Config.documentOcrOpenRouterModel }
}


