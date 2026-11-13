import Foundation
import WimmDomain

// Common metadata keys used in note metadata JSON files
public enum MetadataKey: String {
    // Top-level keys
    case processingStatus = "processingStatus"
    // Deprecated: no longer written to `.meta.json` (derived from file/embedded metadata).
    case importedAt = "importedAt"
    // Deprecated: no longer written to `.meta.json` (derived from file/embedded metadata).
    case createdAt = "createdAt"
    case publishedAt = "publishedAt"        // Publication/send date (e.g., when email was sent)
    case sourcePath = "sourcePath"
    case document = "document"
    case attachments = "attachments"
    case ocr = "ocr"
    case ocrStatus = "ocrStatus"
    case ocrReason = "ocrReason"
    case transcription = "transcription"
    case agentRouting = "agentRouting"
    case contentHash = "contentHash"
    case analysisGlossary = "analysisGlossary"
    // PseudonymizationReceipt@v1 of the last masked analysis (null when unmasked).
    case analysisPseudonymization = "analysisPseudonymization"
    // Device provenance: {"platform": "macOS"|"iPhone"|"iPad", "device": <name>}
    case origin = "origin"
    
    // Attachment/extraction keys
    case type = "type"
    case url = "url"
    case extractedText = "extractedText"
    case extractionProvider = "extractionProvider"
    case extractionModel = "extractionModel"
    
    // Document sub-keys
    case text = "text"
    case textProvider = "textProvider"
    case textModel = "textModel"
    case pageCount = "pageCount"
    
    // Agent routing sub-keys
    case autoRoutedAt = "autoRoutedAt"
}
