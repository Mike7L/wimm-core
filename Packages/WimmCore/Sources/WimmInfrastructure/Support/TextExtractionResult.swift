import Foundation

/// Unified text extraction result structure used across OCR and document processing
public struct TextExtractionResult {
    public let text: String
    public let provider: String
    public let model: String?
    public let pageCount: Int?
    public let imageAnalysis: ImageBatchRecord?
    public let pages: [DocumentPageEvidence]?
    public let sourceSHA256: String?
    
    public init(text: String, provider: String, model: String? = nil, pageCount: Int? = nil, imageAnalysis: ImageBatchRecord? = nil,
                pages: [DocumentPageEvidence]? = nil, sourceSHA256: String? = nil) {
        self.text = text
        self.provider = provider
        self.model = model
        self.pageCount = pageCount
        self.imageAnalysis = imageAnalysis
        self.pages = pages; self.sourceSHA256 = sourceSHA256
    }
}

/// Standard provider names for text extraction
public enum TextExtractionProvider {
    public static let vision = "vision"
    public static let pdfKit = "pdfkit"
    public static let gemini = "gemini"
    public static let openRouter = "openrouter"
    public static let clipboard = "clipboard"
    public static let plainText = "plain-text"
    public static let ocr = "ocr"
    
    /// Localized display name for provider
    public static func displayName(for provider: String) -> String {
        switch provider.lowercased() {
        case vision: return "Apple Vision"
        case pdfKit: return "PDFKit"
        case gemini: return "Gemini"
        case openRouter: return "OpenRouter"
        case clipboard: return "Clipboard"
        case plainText: return "Plain Text"
        case ocr: return "OCR"
        default: return provider.capitalized
        }
    }
}
