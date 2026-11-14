import Foundation
import WimmDomain

/// The diarization stored in a sidecar's `transcription.speakerTurns`. A single-speaker result is
/// stored too (with no turns), so the note is not diarized again for nothing.
public struct SpeakerTurnsRecord: Sendable, Equatable {
    public static let sidecarKey = "speakerTurns"
    public static let schema = 1
    static let voicesKey = "voices"

    public let speakers: Int
    public let engine: String
    public let createdAt: Date
    public let turns: [SpeakerTurns.Turn]
    public let speechClassification: AudioSpeechClassification.Detection?
    /// Who each voice sounds like, by the local person voice profiles. Empty when the voices
    /// were never compared (no profiles on this device, an older record).
    public let voices: [VoiceTag]

    /// One voice compared with the local person voice profiles (`PersonVoiceProfiles`).
    /// Evidence about the voice, not "the note is about this person". `card` is nil when no
    /// profile clearly won; the vectors themselves never leave `VoiceProfile/`.
    public struct VoiceTag: Sendable, Equatable {
        /// The turn's 1-based speaker number.
        public let voice: Int
        public let card: String?
        public let score: Double?
        public let windows: Int

        public init(voice: Int, card: String?, score: Double?, windows: Int) {
            self.voice = voice
            self.card = card
            self.score = score
            self.windows = windows
        }
    }

    public init(speakers: Int, engine: String, createdAt: Date = Date(), turns: [SpeakerTurns.Turn],
                speechClassification: AudioSpeechClassification.Detection? = nil, voices: [VoiceTag] = []) {
        self.speakers = speakers
        self.engine = engine
        self.createdAt = createdAt
        self.turns = turns
        self.speechClassification = speechClassification
        self.voices = voices
    }

    public func with(voices: [VoiceTag]) -> SpeakerTurnsRecord {
        SpeakerTurnsRecord(speakers: speakers, engine: engine, createdAt: createdAt, turns: turns,
                           speechClassification: speechClassification, voices: voices)
    }

    /// The card a voice was tagged with, if any.
    public func card(forVoice voice: Int) -> String? { voices.first { $0.voice == voice }?.card }

    static func voicesValue(_ voices: [VoiceTag]) -> [[String: Any]] {
        voices.map { tag in
            var value: [String: Any] = ["voice": tag.voice, "windows": tag.windows]
            if let card = tag.card { value["card"] = card }
            if let score = tag.score, score.isFinite { value["score"] = (score * 100).rounded() / 100 }
            return value
        }
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
        if !voices.isEmpty { value[Self.voicesKey] = Self.voicesValue(voices) }
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
        self.voices = (dict[Self.voicesKey] as? [[String: Any]] ?? []).compactMap { raw in
            guard let voice = (raw["voice"] as? NSNumber)?.intValue else { return nil }
            let card = (raw["card"] as? String).flatMap { PersonVoiceProfiles.isCardID($0) ? $0 : nil }
            return VoiceTag(voice: voice, card: card, score: (raw["score"] as? NSNumber)?.doubleValue,
                            windows: (raw["windows"] as? NSNumber)?.intValue ?? 0)
        }
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
