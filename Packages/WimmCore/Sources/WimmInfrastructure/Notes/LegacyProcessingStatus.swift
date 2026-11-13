import Foundation

/// Legacy string-based processing status stored in `.meta.json`
/// (`processingStatus` key). Named `Legacy…` because the 2.0 pipeline's
/// `WimmDomain.ProcessingStatus` already owns the plain name; WimmCore
/// re-exports this one as `ProcessingStatus` for its consumers.
public enum LegacyProcessingStatus: String, Codable, Sendable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
    case orphan = "orphan"
}
