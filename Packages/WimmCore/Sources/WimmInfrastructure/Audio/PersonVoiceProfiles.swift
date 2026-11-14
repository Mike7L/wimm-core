import Foundation
import WimmDomain

/// Local voice profiles keyed by a people-card id (`P003`), and the rule that tags a voice in
/// a recording with a card. User decision 2026-11-12
/// (docs/Speakers_Who_Is_Talking_Concept_2026-11-12.md): the tag is evidence about who is
/// speaking, never "the note is about this person"; code does not merge or split cards.
///
/// Biometric data: a profile is built only from audio the user labelled by ear, lives under
/// `VoiceProfile/people/`, and never goes into sidecars, CloudKit or secretary packets.
public enum PersonVoiceProfiles {
    /// Median cosine a voice needs to be tagged; the same value the owner check uses.
    public static let threshold = 0.5
    /// The best card must beat the second best by this much, or the voice stays untagged.
    public static let margin = 0.1
    /// Below this many windows a score is too noisy to tag anyone (measured: 3 windows gave 0.45
    /// for a voice that scores 0.7 with enough audio).
    public static let minimumWindows = 4
    /// Windows read per voice. Five (the owner check) is noisy on mixed recordings.
    public static let windowsPerVoice = 15

    public struct Identification: Sendable, Equatable {
        public let card: String?
        /// The best card and its score even when it did not pass, for diagnostics.
        public let best: String?
        public let score: Double?
        public let windows: Int
    }

    public static var directory: URL {
        OwnerVoiceProfile.url.deletingLastPathComponent().appendingPathComponent("people")
    }

    /// Only person cards (`P` + digits) can have a voice.
    public static func isCardID(_ value: String) -> Bool {
        value.count >= 2 && value.first == "P" && value.dropFirst().allSatisfy(\.isASCII) &&
        value.dropFirst().allSatisfy(\.isNumber)
    }

    public static func load() -> [String: OwnerVoiceProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [String: OwnerVoiceProfile] = [:]
        for file in files where file.pathExtension == "json" {
            let card = file.deletingPathExtension().lastPathComponent
            guard isCardID(card), let data = try? Data(contentsOf: file),
                  let profile = try? JSONDecoder().decode(OwnerVoiceProfile.self, from: data),
                  profile.isValid else { continue }
            result[card] = profile
        }
        return result
    }

    public static func install(_ profile: OwnerVoiceProfile, card: String) throws {
        guard isCardID(card), profile.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(card).json")
        try JSONEncoder().encode(profile).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The unit-length mean of unit-length window vectors.
    public static func profile(from vectors: [[Double]], source: String,
                               embeddingWeightsSHA256: String, fbankWeightsSHA256: String) -> OwnerVoiceProfile? {
        guard let first = vectors.first, vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Double](repeating: 0, count: first.count)
        for vector in vectors { for index in vector.indices { sum[index] += vector[index] } }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 0, norm.isFinite else { return nil }
        let profile = OwnerVoiceProfile(
            schema: 1, model: OwnerVoiceProfile.model, embedding: sum.map { $0 / norm }, threshold: threshold,
            source: source, embeddingWeightsSHA256: embeddingWeightsSHA256, fbankWeightsSHA256: fbankWeightsSHA256)
        return profile.isValid ? profile : nil
    }

    /// Median cosine of the voice's windows against one profile.
    public static func score(_ vectors: [[Double]], against profile: OwnerVoiceProfile) -> Double? {
        let scores = vectors.map { zip($0, profile.embedding).reduce(0) { $0 + $1.0 * $1.1 } }.sorted()
        guard !scores.isEmpty, scores.allSatisfy(\.isFinite) else { return nil }
        return scores[scores.count / 2]
    }

    /// Tags a voice with a card only when one profile clearly wins. Profiles made with other
    /// model weights are ignored instead of compared.
    public static func identify(_ vectors: [[Double]], profiles: [String: OwnerVoiceProfile],
                                embeddingWeightsSHA256: String, fbankWeightsSHA256: String) -> Identification {
        let ranked = profiles
            .filter { $0.value.embeddingWeightsSHA256 == embeddingWeightsSHA256 && $0.value.fbankWeightsSHA256 == fbankWeightsSHA256 }
            .compactMap { card, profile in score(vectors, against: profile).map { (card: card, score: $0) } }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.card < $1.card }
        guard let best = ranked.first else {
            return Identification(card: nil, best: nil, score: nil, windows: vectors.count)
        }
        let runnerUp = ranked.dropFirst().first?.score ?? -1
        let accepted = vectors.count >= minimumWindows && best.score >= threshold && best.score - runnerUp >= margin
        return Identification(card: accepted ? best.card : nil, best: best.card, score: best.score, windows: vectors.count)
    }

    // MARK: - Tagging a recording's voices

    /// Compares every voice of a split with the local profiles. Voice N is the turns' speaker N;
    /// a one-voice record (no turns) is voice 1 over all `spans`. Empty when there are no
    /// profiles or nothing could be read: a missing tag never fails the split.
    public static func tags(file: URL, turns: [SpeakerTurns.Turn], spans: [SpeakerTurns.Span]) async -> [SpeakerTurnsRecord.VoiceTag] {
        let profiles = load()
        guard !profiles.isEmpty else { return [] }
        var byVoice: [(voice: Int, spans: [SpeakerTurns.Span])] = Set(turns.map(\.speaker)).sorted().map { voice in
            (voice, turns.filter { $0.speaker == voice }.map { SpeakerTurns.Span(speaker: "\(voice)", start: $0.start, end: $0.end) })
        }
        if byVoice.count < 2 { byVoice = spans.isEmpty ? [] : [(1, spans)] }
        var result: [SpeakerTurnsRecord.VoiceTag] = []
        for (voice, spans) in byVoice {
            guard let read = try? await OwnerVoiceVerifier.embeddings(file: file, spans: spans, limit: windowsPerVoice) else { continue }
            let found = identify(read.windows.map(\.embedding), profiles: profiles,
                                 embeddingWeightsSHA256: read.embeddingWeightsSHA256, fbankWeightsSHA256: read.fbankWeightsSHA256)
            result.append(.init(voice: voice, card: found.card, score: found.score, windows: found.windows))
        }
        return result
    }

    /// Writes the tags into the note's stored split, only while that split is still the one
    /// they were computed for. Never creates a split.
    @discardableResult
    public static func store(_ tags: [SpeakerTurnsRecord.VoiceTag], for file: URL, ifSplitCreatedAt createdAt: Date) -> Bool {
        var stored = false
        FileStore.mutateTranscription(for: file) { transcription in
            guard var split = transcription[SpeakerTurnsRecord.sidecarKey] as? [String: Any],
                  let record = SpeakerTurnsRecord(sidecarValue: split),
                  abs(record.createdAt.timeIntervalSince(createdAt)) < 1 else { return false }
            if tags.isEmpty { split.removeValue(forKey: SpeakerTurnsRecord.voicesKey) }
            else { split[SpeakerTurnsRecord.voicesKey] = SpeakerTurnsRecord.voicesValue(tags) }
            transcription[SpeakerTurnsRecord.sidecarKey] = split
            stored = true
            return true
        }
        return stored
    }
}
