import Foundation
import WimmDomain
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// On-device "who spoke when" (FluidAudio's offline pyannote pipeline), run after a recording
/// ends, never live: ~160× realtime and ~700 MB peak on an M1, and on 6 real Russian
/// conversations it confused speakers on 0–2 % of words. Its weak spot is quiet speech, which
/// it often leaves uncovered — `SpeakerTurns` gives such words the nearest speaker.
public enum LocalSpeakerDiarizer {
    public static let engine = "fluidaudio-offline"

    /// Shorter notes are dictation, not conversation; diarizing them costs a model load for nothing.
    public static let minimumAudioSeconds: Double = 20

    /// Diarizes the file and matches the given words to speakers.
    public static func record(for file: URL, words: [SpeakerTurns.Word]) async throws -> SpeakerTurnsRecord {
        let started = Date()
        let spans = try await spans(for: file)
        let turns = SpeakerTurns.turns(words: words, spans: spans)
        let speakers = Set(spans.map(\.speaker)).count
        // An unavailable voice profile/model must never fail the speaker split.
        let classification = try? await AudioSpeechClassification.classify(file: file, spans: spans)
        try Task.checkCancellation()
        log(String(format: "[Diarization] %@ speakers=%d spans=%d turns=%d took=%.1fs",
                   file.lastPathComponent, speakers, spans.count, turns.count, Date().timeIntervalSince(started)))
        return SpeakerTurnsRecord(
            speakers: speakers, engine: engine,
            turns: speakers > 1 ? turns : [], speechClassification: classification)
    }

    public static func preload() async throws {
        #if canImport(FluidAudio)
        try await OfflineDiarizerCache.shared.preload()
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    public static func spans(for file: URL) async throws -> [SpeakerTurns.Span] {
        #if canImport(FluidAudio)
        return try await OfflineDiarizerCache.shared.spans(for: file)
        #else
        throw NSError(domain: "LocalSpeakerDiarizer", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Speaker diarization unavailable in current build."])
        #endif
    }
}

#if canImport(FluidAudio)
/// One loaded diarizer for the life of the process; the first load downloads and compiles it.
/// `OfflineDiarizerManager` is not Sendable and not safe to run twice at once. The shared
/// inference permit serializes access, defers new work during live preview, and cancels waiters.
actor OfflineDiarizerCache {
    static let shared = OfflineDiarizerCache()

    private nonisolated(unsafe) var manager: OfflineDiarizerManager?

    func preload() async throws {
        try await LocalInferenceScheduler.shared.withPermit(priority: .file) { _ = try await self.loadedManager() }
    }

    func spans(for file: URL) async throws -> [SpeakerTurns.Span] {
        try await LocalInferenceScheduler.shared.withPermit(priority: .background) {
            do {
                let result = try await self.run(file)
                await LocalModelResources.touch("diarizer")
                return result
            } catch {
                await LocalModelResources.touch("diarizer")
                throw error
            }
        }
    }

    private nonisolated func run(_ file: URL) async throws -> [SpeakerTurns.Span] {
        let manager = try await loadedManager()
        try Task.checkCancellation()
        let result: DiarizationResult
        do {
            result = try await manager.process(file)
        } catch OfflineDiarizationError.noSpeechDetected {
            // An answer, not a failure: quiet speech Parakeet still read (seen on real dictation).
            // No spans → a zero-speaker record, stored, so the note is not diarized again.
            return []
        }
        return result.segments.map {
            SpeakerTurns.Span(
                speaker: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds))
        }
    }

    private func unload() { manager = nil }

    private nonisolated func loadedManager() async throws -> OfflineDiarizerManager {
        if let manager {
            await LocalModelResources.used("diarizer") { await self.unload() }
            return manager
        }
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        self.manager = manager
        await LocalModelResources.used("diarizer") { await self.unload() }
        return manager
    }
}
#endif
