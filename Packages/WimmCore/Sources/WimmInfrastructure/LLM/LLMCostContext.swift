import Foundation

/// Ambient attribution for cost accounting.
///
/// Which note a call belongs to is known at the call site (`NoteProcessor`,
/// the transcription adapters), but the logging happens several layers down in
/// `LLMJSONClient`. Threading two extra parameters through every intermediate
/// signature would touch far more code than it is worth, so the attribution
/// rides along as task-local state — the same trick already used by
/// ``LLMQueueContext``.
///
/// Anything not wrapped simply logs without `note_file`; the operation still
/// gets inferred from the request shape.
public enum LLMCostContext {
    @TaskLocal public static var noteFile: String?
    @TaskLocal public static var operation: LLMOperation?

    /// Runs `body` with the given attribution attached to every LLM call it makes.
    public static func with<T>(
        noteFile: String? = nil,
        operation: LLMOperation? = nil,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await $noteFile.withValue(noteFile ?? Self.noteFile) {
            try await $operation.withValue(operation ?? Self.operation) {
                try await body()
            }
        }
    }

    /// Fallback when the call site said nothing: derive the operation from what
    /// the request looks like. Deliberately coarse — the point is that every
    /// logged call lands in *some* bucket, so totals add up.
    public static func inferOperation(requestKind: String, capability: ModelCapability) -> LLMOperation {
        switch requestKind {
        case "note_card": return .card
        case "notes_analysis", "combine_cards", "seed_merge": return .card
        case "instruction": return .agent
        default:
            return capability == .see ? .ocr : .other
        }
    }
}
