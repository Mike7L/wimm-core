import Foundation
import WimmDomain

/// Read-only inference followed by a guarded metadata-only write. No transcript
/// generation, cloud request, or learning from automatic predictions.
public enum AudioSpeechClassification {
    public static let key = "speechClassification"
    public static let overrideKey = "audioSpeechLabelOverride"

    public struct Detection: Codable, Sendable, Equatable {
        public let label: AudioSpeechLabel
        public let ownerScore: Double?
        public let profileID: String?

        public var metadata: [String: Any] {
            var value: [String: Any] = ["schema": 1, "label": label.rawValue]
            if let ownerScore { value["ownerScore"] = ownerScore }
            if let profileID { value["profileID"] = profileID }
            return value
        }
    }

    public static func detected(in metadata: [String: Any], speechStatus: TranscriptionSpeechStatus?) -> AudioSpeechLabel? {
        if speechStatus == .noSpeech { return .noSpeech }
        let transcription = FileStore.transcriptionDictionary(from: metadata["transcription"]) ?? [:]
        if let result = transcription[key] as? [String: Any],
           let raw = result["label"] as? String, let label = AudioSpeechLabel(rawValue: raw) {
            return label
        }
        if let split = transcription[SpeakerTurnsRecord.sidecarKey] as? [String: Any] {
            if let result = split[key] as? [String: Any],
               let raw = result["label"] as? String, let label = AudioSpeechLabel(rawValue: raw) {
                return label
            }
            if let count = split["speakers"] as? Int { return .speakerCount(count) }
        }
        return nil
    }

    public static func override(in metadata: [String: Any]) -> AudioSpeechLabel? {
        (metadata[overrideKey] as? String).flatMap(AudioSpeechLabel.init(rawValue:))
    }

    public static func setOverride(_ label: AudioSpeechLabel?, for file: URL) throws {
        guard FileStore.isAudioFile(file), !FileStore.isAttachmentFile(file), !FileStore.isDerivedAudioFile(file) else { return }
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
            guard FileManager.default.fileExists(atPath: file.path) else { return false }
            if let label {
                guard metadata[overrideKey] as? String != label.rawValue else { return false }
                metadata[overrideKey] = label.rawValue
            } else {
                guard metadata.removeValue(forKey: overrideKey) != nil else { return false }
            }
            return true
        }
    }

    public static func classify(file: URL, spans: [SpeakerTurns.Span]) async throws -> Detection? {
        let count = Set(spans.map(\.speaker)).count
        guard let label = AudioSpeechLabel.speakerCount(count) else { return nil }
        guard count == 1 else {
            return Detection(label: label, ownerScore: nil, profileID: nil)
        }
        let match: OwnerVoiceVerifier.Match?
        do { match = try await OwnerVoiceVerifier.match(file: file, spans: spans) }
        catch is CancellationError { throw CancellationError() }
        catch {
            log("[SpeechLabel] Owner verification unavailable: \(error)")
            return Detection(label: label, ownerScore: nil, profileID: nil)
        }
        guard let match else { return Detection(label: label, ownerScore: nil, profileID: nil) }
        return Detection(label: match.isOwner ? .owner : .onePerson,
                         ownerScore: match.score, profileID: match.profileID)
    }

    /// On-demand catch-up for an opened recording, including short/cloud notes
    /// that never went through the Parakeet speaker backfill.
    public static func detectIfNeeded(for file: URL) async throws {
        guard FileStore.isAudioFile(file), !FileStore.isAttachmentFile(file), !FileStore.isDerivedAudioFile(file) else { return }
        let sidecar = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: sidecar),
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard override(in: metadata) == nil else { return }
        let transcription = FileStore.transcriptionDictionary(from: metadata["transcription"]) ?? [:]
        guard transcription["speechStatus"] as? String != TranscriptionSpeechStatus.noSpeech.rawValue else { return }
        let split = transcription[SpeakerTurnsRecord.sidecarKey] as? [String: Any]
        let existing = (transcription[key] as? [String: Any]) ?? (split?[key] as? [String: Any])
        let profileID = OwnerVoiceProfile.load()?.id
        if let existing {
            let label = (existing["label"] as? String).flatMap(AudioSpeechLabel.init(rawValue:))
            if label == .twoPeople || label == .threeOrMore { return }
            if existing["profileID"] as? String == profileID { return }
        }
        // A known multi-speaker result already provides the complete label.
        if let count = split?["speakers"] as? Int, count > 1 { return }
        let transcript = transcription["transcript"] as? String
        let spans = try await LocalSpeakerDiarizer.spans(for: file)
        try Task.checkCancellation()
        guard let result = try await classify(file: file, spans: spans) else { return }
        try Task.checkCancellation()
        try FileStore.mutateSidecar(at: sidecar) { current in
            guard !current.isEmpty, FileManager.default.fileExists(atPath: file.path) else { return false }
            guard current[overrideKey] == nil else { return false }
            var latest = FileStore.transcriptionDictionary(from: current["transcription"]) ?? [:]
            guard latest["transcript"] as? String == transcript,
                  latest["speechStatus"] as? String == transcription["speechStatus"] as? String else { return false }
            latest[key] = result.metadata
            current["transcription"] = latest
            return true
        }
    }
}
