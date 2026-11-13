import Foundation

public enum ModelCapability: String, Codable, Sendable {
    case hear        // Transcribe audio
    case see         // OCR + Visual understanding
    case understand  // Reading and extraction (PDF, Docs)
    case think       // Cognitive tasks (AnalysisCard, Chat, Assignment)
}
