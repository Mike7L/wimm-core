import Foundation

/// Builds one recording-wide transcript from recognizer results whose partial
/// text may reset after a finalized utterance or recognition-session restart.
///
/// Partial results revise the current utterance, so they replace
/// `currentPartial` rather than being appended. Only a finalized utterance is
/// moved into `committedText`.
public struct StreamingTranscriptAccumulator: Sendable {
    public private(set) var committedText = ""
    public private(set) var currentPartial = ""

    public init() {}

    public var text: String {
        Self.joined(committedText, currentPartial)
    }

    /// Replaces the current partial hypothesis and optionally commits it.
    ///
    /// - Parameters:
    ///   - partial: The recognizer's complete hypothesis for its current
    ///     utterance/session, not a delta from the previous callback.
    ///   - isFinalized: Whether the recognizer has finalized this utterance.
    /// - Returns: The complete hypothesis accumulated for the recording.
    @discardableResult
    public mutating func update(partial: String, isFinalized: Bool) -> String {
        currentPartial = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinalized {
            return commitCurrentPartial()
        }
        return text
    }

    /// Banks the latest partial before a recognition session is replaced.
    @discardableResult
    public mutating func commitCurrentPartial() -> String {
        committedText = text
        currentPartial = ""
        return committedText
    }

    public mutating func reset() {
        committedText = ""
        currentPartial = ""
    }

    private static func joined(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}
