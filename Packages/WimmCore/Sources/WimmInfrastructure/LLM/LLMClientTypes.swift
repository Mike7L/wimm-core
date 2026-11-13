import Foundation
import WimmDomain

// MARK: - Note Extraction

/// Intermediate DTO for NoteCard extraction response from LLM
public struct NoteCardExtractionResult: Decodable {
    public let schema: String?
    public let note_id: String?
    public let note_file: String?
    public let lang: String?
    public let title: String
    public let summary: String
    public let refined_text: String?
    public let agent_recommendation: String?
    public let agent_reason: String?
}
