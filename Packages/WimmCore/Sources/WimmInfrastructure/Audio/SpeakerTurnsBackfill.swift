import CryptoKit
import Foundation
import WimmDomain
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// Catches up the speaker split a Parakeet note should have but does not.
///
/// The split after a Parakeet run is detached and best-effort: the process can be killed in the
/// middle (iOS in the background, the app quit), or the diarizer can fail, and nothing retries it.
/// A note is a candidate when its current transcript is a Parakeet run of at least
/// `LocalSpeakerDiarizer.minimumAudioSeconds` with speech and no `speakerTurns`.
///
/// Word timings are not stored, so the backfill reads the original again with the same Parakeet
/// variant and uses the timings only when that read gives exactly the stored text. The split is
/// written only while the stored transcript is still that text — never over a newer transcript.
/// A note that cannot be split for its current text (a different re-read, too short, failed
/// `maxFailedAttempts` times) gets a `speakerTurnsSkipped` marker keyed by the transcript's hash,
/// so a rerun does not pay for it again; a new transcript makes it a candidate again.
public enum SpeakerTurnsBackfill {
    public static let skipKey = "speakerTurnsSkipped"
    public static let maxFailedAttempts = 3

    public struct Candidate: Sendable, Equatable {
        /// The original audio the sidecar belongs to — Parakeet never reads the `_micro`.
        public let audio: URL
        public let transcript: String
        /// The full hear-model id, e.g. `parakeet:ultra`.
        public let model: String
        public let audioSeconds: Double?
    }

    public enum Outcome: Sendable, Equatable {
        case stored(speakers: Int)
        /// Dry run: what would have been stored.
        case wouldStore(speakers: Int)
        /// The note got a new transcript while it was being split; nothing was written.
        case transcriptChanged
        /// Parakeet read the file into a different text than the stored one.
        case textMismatch
        case tooShort
        case failed(String)
    }

    public typealias Transcribe = @Sendable (_ audio: URL, _ model: String, _ language: String) async throws -> ParakeetTranscript
    public typealias Diarize = @Sendable (_ audio: URL, _ words: [SpeakerTurns.Word]) async throws -> SpeakerTurnsRecord

    // MARK: - Candidates

    /// Every candidate among the originals in `directory`, in filename (= capture) order.
    public static func candidates(in directory: URL = FileStore.recordingsDirectory()) -> [Candidate] {
        let audioExtensions = DefaultFileStore.shared.supportedAudioExtensions
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) && !FileStore.isDerivedAudioFile($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap(candidate(for:))
    }

    public static func candidate(for audio: URL) -> Candidate? {
        let metaURL = FileStore.metadataURL(forRecordingURL: audio)
        guard let data = try? Data(contentsOf: metaURL),
              let sidecar = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let transcription = sidecar["transcription"] as? [String: Any] else { return nil }
        return candidate(audio: audio, transcription: transcription)
    }

    static func candidate(audio: URL, transcription t: [String: Any]) -> Candidate? {
        guard (t["provider"] as? String) == "parakeet",
              t[SpeakerTurnsRecord.sidecarKey] == nil,
              (t["speechStatus"] as? String) != TranscriptionSpeechStatus.noSpeech.rawValue,
              let text = normalized(t["transcript"] as? String),
              !text.contains("[[NO_SPEECH]]") else { return nil }
        let audioSeconds = (t["audioDurationSec"] as? NSNumber)?.doubleValue
        if let audioSeconds, audioSeconds < LocalSpeakerDiarizer.minimumAudioSeconds { return nil }
        if let skip = t[skipKey] as? [String: Any], (skip["transcriptSHA256"] as? String) == sha256(text) {
            let failedOnly = (skip["reason"] as? String) == "failed"
            let attempts = (skip["attempts"] as? NSNumber)?.intValue ?? maxFailedAttempts
            if !failedOnly || attempts >= maxFailedAttempts { return nil }
        }
        let variant = (t["model"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "ultra"
        let model = ParakeetModel.isParakeet(variant) ? variant : ParakeetModel.prefix + variant
        return Candidate(audio: audio, transcript: text, model: model, audioSeconds: audioSeconds)
    }

    // MARK: - Run

    /// Splits one candidate. `languages` are tried in order until a read reproduces the stored
    /// text (the language only picks Parakeet's alphabet, and the run's language is not stored).
    /// With `apply == false` nothing is written, not even a skip marker.
    public static func run(
        _ candidate: Candidate,
        languages: [String],
        apply: Bool,
        transcribe: Transcribe,
        diarize: Diarize
    ) async -> Outcome {
        let file = candidate.audio
        var matched: ParakeetTranscript?
        var tried = Set<String>()
        do {
            for language in languages + ["Auto"] where tried.insert(language.lowercased()).inserted {
                try Task.checkCancellation()
                let read = try await transcribe(file, candidate.model, language)
                if normalized(read.text) == candidate.transcript { matched = read; break }
            }
        } catch {
            if apply { markFailedAttempt(file, transcript: candidate.transcript, error: error) }
            return .failed(error.localizedDescription)
        }
        guard let matched else {
            if apply { markSkipped(file, transcript: candidate.transcript, reason: "text-mismatch") }
            return .textMismatch
        }
        guard matched.audioSeconds >= LocalSpeakerDiarizer.minimumAudioSeconds, !matched.timedWords.isEmpty else {
            if apply { markSkipped(file, transcript: candidate.transcript, reason: "too-short") }
            return .tooShort
        }
        let record: SpeakerTurnsRecord
        do {
            try Task.checkCancellation()
            record = try await diarize(file, matched.timedWords)
        } catch {
            if apply { markFailedAttempt(file, transcript: candidate.transcript, error: error) }
            return .failed(error.localizedDescription)
        }
        guard apply else { return .wouldStore(speakers: record.speakers) }
        return store(record, for: file, ifTranscriptIs: candidate.transcript)
            ? .stored(speakers: record.speakers) : .transcriptChanged
    }

    // MARK: - Writes (all through `mutateTranscription`)

    /// Stores the split only while the note's transcript is still `text`; clears a skip marker.
    @discardableResult
    public static func store(_ record: SpeakerTurnsRecord, for file: URL, ifTranscriptIs text: String) -> Bool {
        var stored = false
        FileStore.mutateTranscription(for: file) { transcription in
            guard normalized(transcription["transcript"] as? String) == normalized(text) else { return false }
            transcription[SpeakerTurnsRecord.sidecarKey] = record.sidecarValue
            transcription.removeValue(forKey: AudioSpeechClassification.key)
            transcription.removeValue(forKey: skipKey)
            stored = true
            return true
        }
        return stored
    }

    /// Counts a failed split of the current transcript; after `maxFailedAttempts` the backfill
    /// stops trying until the transcript changes. A killed process counts nothing.
    public static func markFailedAttempt(_ file: URL, transcript text: String, error: Error) {
        guard !(error is CancellationError) else { return }
        let hash = sha256(normalized(text) ?? "")
        FileStore.mutateTranscription(for: file) { transcription in
            guard normalized(transcription["transcript"] as? String) == normalized(text),
                  transcription[SpeakerTurnsRecord.sidecarKey] == nil else { return false }
            let previous = transcription[skipKey] as? [String: Any]
            let attempts = (previous?["transcriptSHA256"] as? String) == hash
                ? ((previous?["attempts"] as? NSNumber)?.intValue ?? 0) + 1 : 1
            transcription[skipKey] = marker(hash: hash, reason: "failed", attempts: attempts,
                                            error: error.localizedDescription)
            return true
        }
    }

    static func markSkipped(_ file: URL, transcript text: String, reason: String) {
        let hash = sha256(normalized(text) ?? "")
        FileStore.mutateTranscription(for: file) { transcription in
            guard normalized(transcription["transcript"] as? String) == normalized(text),
                  transcription[SpeakerTurnsRecord.sidecarKey] == nil else { return false }
            transcription[skipKey] = marker(hash: hash, reason: reason, attempts: nil, error: nil)
            return true
        }
    }

    private static func marker(hash: String, reason: String, attempts: Int?, error: String?) -> [String: Any] {
        var value: [String: Any] = [
            "transcriptSHA256": hash,
            "reason": reason,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        if let attempts { value["attempts"] = attempts }
        if let error { value["error"] = String(error.prefix(300)) }
        return value
    }

    // MARK: - Background time

    /// Begins background time named `name` and returns the closure that ends it; `expired` is
    /// called when the OS takes the time back. Installed by the iOS app
    /// (`UIApplication.beginBackgroundTask`); nil on the Mac, where nothing suspends the work.
    public typealias BackgroundTimeHolder = @Sendable (
        _ name: String, _ expired: @escaping @Sendable () -> Void
    ) async -> @Sendable () async -> Void

    private static let holder = HolderBox()

    public static var backgroundTimeHolder: BackgroundTimeHolder? {
        get { holder.value }
        set { holder.value = newValue }
    }

    /// Runs a split while holding background time, so a split that is already computing is
    /// written instead of being frozen with the app. When the time runs out the work is
    /// cancelled: the diarizer may still finish (its result is then stored), and a split that
    /// does not finish counts no failed attempt and is caught up later.
    public static func withBackgroundTime(_ name: String, _ work: @escaping @Sendable () async -> Void) async {
        guard let hold = backgroundTimeHolder else { return await work() }
        let task = Task { await work() }
        let end = await hold(name) { task.cancel() }
        await task.value
        await end()
    }

    private final class HolderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: BackgroundTimeHolder?
        var value: BackgroundTimeHolder? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    static func normalized(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

#if canImport(FluidAudio)
extension SpeakerTurnsBackfill {
    /// The real models: Parakeet for the timings, the offline diarizer for the spans.
    public static let onDeviceTranscribe: Transcribe = { audio, model, language in
        try await ParakeetTranscriptionAdapter(modelIdentifier: model, language: language).transcribeForSpeakerBackfill(at: audio)
    }
    public static let onDeviceDiarize: Diarize = { audio, words in
        try await LocalSpeakerDiarizer.record(for: audio, words: words)
    }

    /// Splits every candidate in the library, one at a time. Returns how many were stored.
    @discardableResult
    public static func runPending(languages: [String]) async -> Int {
        let pending = candidates()
        guard !pending.isEmpty else { return 0 }
        log("[Diarization] backfill: \(pending.count) note(s) without a speaker split")
        var stored = 0
        for candidate in pending {
            if Task.isCancelled { break }
            let box = OutcomeBox()
            await withBackgroundTime("Wimm speaker split") {
                box.value = await run(candidate, languages: languages, apply: true,
                                      transcribe: onDeviceTranscribe, diarize: onDeviceDiarize)
            }
            guard let outcome = box.value else { continue }
            if case .stored = outcome { stored += 1 }
            log("[Diarization] backfill \(candidate.audio.lastPathComponent) → \(outcome)")
        }
        log("[Diarization] backfill done: stored=\(stored) of \(pending.count)")
        return stored
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: Outcome?
    }
}
#endif
