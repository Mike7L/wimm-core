import Foundation
import WimmDomain

/// The diarization stored in a sidecar's `transcription.speakerTurns`. A single-speaker result is
/// stored too (with no turns), so the note is not diarized again for nothing.
public struct SpeakerTurnsRecord: Sendable, Equatable {
    public static let sidecarKey = "speakerTurns"
    public static let schema = 1

    public let speakers: Int
    public let engine: String
    public let createdAt: Date
    public let turns: [SpeakerTurns.Turn]
    public let speechClassification: AudioSpeechClassification.Detection?

    public init(speakers: Int, engine: String, createdAt: Date = Date(), turns: [SpeakerTurns.Turn],
                speechClassification: AudioSpeechClassification.Detection? = nil) {
        self.speakers = speakers
        self.engine = engine
        self.createdAt = createdAt
        self.turns = turns
        self.speechClassification = speechClassification
    }

    /// Only worth showing when it actually separates people.
    public var isMultiSpeaker: Bool { speakers > 1 && Set(turns.map(\.speaker)).count > 1 }

    public var sidecarValue: [String: Any] {
        var value: [String: Any] = [
            "schema": Self.schema,
            "speakers": speakers,
            "engine": engine,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "turns": turns.map { turn in
                [
                    "speaker": turn.speaker,
                    "start": (turn.start * 100).rounded() / 100,
                    "end": (turn.end * 100).rounded() / 100,
                    "text": turn.text,
                ] as [String: Any]
            },
        ]
        if let speechClassification { value[AudioSpeechClassification.key] = speechClassification.metadata }
        return value
    }

    public init?(sidecarValue value: Any?) {
        guard let dict = value as? [String: Any],
              let speakers = (dict["speakers"] as? NSNumber)?.intValue else { return nil }
        let rawTurns = dict["turns"] as? [[String: Any]] ?? []
        self.speakers = speakers
        self.engine = dict["engine"] as? String ?? ""
        if let value = dict[AudioSpeechClassification.key] as? [String: Any],
           let raw = value["label"] as? String, let label = AudioSpeechLabel(rawValue: raw) {
            self.speechClassification = .init(label: label, ownerScore: value["ownerScore"] as? Double,
                                               profileID: value["profileID"] as? String)
        } else { self.speechClassification = nil }
        self.createdAt = (dict["createdAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast
        self.turns = rawTurns.compactMap { raw in
            guard let speaker = (raw["speaker"] as? NSNumber)?.intValue,
                  let text = raw["text"] as? String else { return nil }
            return SpeakerTurns.Turn(
                speaker: speaker,
                start: (raw["start"] as? NSNumber)?.doubleValue ?? 0,
                end: (raw["end"] as? NSNumber)?.doubleValue ?? 0,
                text: text)
        }
    }
}
