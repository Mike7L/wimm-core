import Foundation

/// Who said what: Parakeet's word timings matched against an offline diarizer's speaker spans.
///
/// Measured on 6 real Russian conversations (docs/FluidAudio_Local_ASR_Diarization_Bakeoff.md):
/// the diarizer almost never confuses two speakers (0–2 %), but its segmentation covers only
/// ~65 % of the word time on quiet phone recordings. So a word with no covering span is the
/// common case, not an error — it goes to the nearest span, and otherwise stays with the
/// previous speaker, instead of being dropped.
public enum SpeakerTurns {
    public struct Word: Sendable, Equatable {
        public let text: String
        public let start: Double
        public let end: Double
        public let confidence: Float?

        public init(text: String, start: Double, end: Double, confidence: Float? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    public struct Span: Sendable, Equatable {
        public let speaker: String
        public let start: Double
        public let end: Double

        public init(speaker: String, start: Double, end: Double) {
            self.speaker = speaker
            self.start = start
            self.end = end
        }
    }

    /// One uninterrupted stretch of one speaker. `speaker` is 1-based, numbered by first appearance.
    public struct Turn: Sendable, Equatable {
        public let speaker: Int
        public let start: Double
        public let end: Double
        public let text: String

        public init(speaker: Int, start: Double, end: Double, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    /// A word farther than this from every span keeps the previous word's speaker.
    static let nearestSpanReach: Double = 1.0

    public static func turns(words: [Word], spans: [Span]) -> [Turn] {
        guard !words.isEmpty else { return [] }
        let sortedSpans = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }

        var numbering: [String: Int] = [:]
        var turns: [Turn] = []
        var previousSpeaker: String?

        for word in words {
            let label = speaker(for: word, in: sortedSpans) ?? previousSpeaker ?? sortedSpans.first?.speaker ?? "?"
            previousSpeaker = label
            let number: Int
            if let known = numbering[label] {
                number = known
            } else {
                number = numbering.count + 1
                numbering[label] = number
            }
            if let last = turns.last, last.speaker == number {
                turns[turns.count - 1] = Turn(
                    speaker: number, start: last.start, end: word.end, text: last.text + " " + word.text)
            } else {
                turns.append(Turn(speaker: number, start: word.start, end: word.end, text: word.text))
            }
        }
        return turns
    }

    /// The span overlapping the word the most; failing that, the nearest one within reach.
    static func speaker(for word: Word, in spans: [Span]) -> String? {
        var best: (speaker: String, overlap: Double)?
        var nearest: (speaker: String, distance: Double)?
        for span in spans {
            let overlap = min(word.end, span.end) - max(word.start, span.start)
            if overlap > 0 {
                if overlap > (best?.overlap ?? 0) { best = (span.speaker, overlap) }
                continue
            }
            let distance = span.end <= word.start ? word.start - span.end : span.start - word.end
            if distance <= nearestSpanReach, distance < (nearest?.distance ?? .infinity) {
                nearest = (span.speaker, distance)
            }
        }
        return best?.speaker ?? nearest?.speaker
    }

    /// "Голос 1: …" paragraphs, one per turn — readable, copyable, and usable as the note body.
    public static func render(_ turns: [Turn], label: (Int) -> String) -> String {
        turns.map { "\(label($0.speaker)): \($0.text)" }.joined(separator: "\n\n")
    }
}
