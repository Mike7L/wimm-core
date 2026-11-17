import Foundation
import WimmDomain
#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

/// On-device Russian text-to-speech with Supertonic-3 (FluidAudio, Core ML on the Neural
/// Engine). A 6 s line takes well under a second once loaded, so a caller can synthesize
/// line by line as text streams in. The first load downloads ~100 MB into FluidAudio's
/// cache and compiles for the Neural Engine (~40 s); later loads take about a second.
/// Nothing leaves the Mac, so private mode does not apply.
public actor NeuralSpeech {
    public static let shared = NeuralSpeech()

    /// Supertonic-3's built-in voice styles: female `F1`…`F5`, male `M1`…`M5`.
    public struct Voice: Hashable, Sendable {
        public let name: String
        public init(_ name: String) { self.name = name }
    }

    public static let sampleRate: Double = 44_100

    #if canImport(FluidAudio)
    private var manager: Supertonic3Manager?
    private var styles: [Voice: Supertonic3VoiceStyle] = [:]
    private var styleLoads: [Voice: Task<Supertonic3VoiceStyle, Error>] = [:]
    /// Voice loads started since no caller was loading voices, for one log line.
    private var styleBurst: (started: Date, count: Int)?
    #endif
    private var voiceLoaders = 0
    private let modelLoad = SingleFlight()
    private let warmUp = SingleFlight()
    private var warmed = false
    private let startGate = StartGate()

    /// Work the model load must wait for. Studio passes its Parakeet preload: the Supertonic
    /// compile and the Parakeet compile both go to the Neural Engine, and on 2026-11-16 the
    /// voice warm-up took 170 s while the live transcriber could not load its model in time.
    /// Live text matters more than the voice, so the voice goes second. Without a gate (the
    /// CLI) the model loads at once.
    public nonisolated func loadAfter(_ gate: @escaping @Sendable () async -> Void) {
        startGate.set(gate)
    }

    /// Loads the model and the voices and runs one short phrase, so the first real line
    /// does not pay for the Neural Engine compile. Safe to call repeatedly and from several
    /// places at once: the load and the warm-up each run once (two players used to warm
    /// the model twice in parallel, and each logged its own line).
    public func prepare(voices: [Voice]) async throws {
        #if canImport(FluidAudio)
        let gate = startGate.current
        // Utility, not the caller's priority: the voice is never more urgent than capture.
        try await modelLoad.run(priority: .utility) {
            let requested = Date()
            if let gate {
                await gate()
                let waited = Date().timeIntervalSince(requested)
                if waited >= 0.5 {
                    log(String(format: "[NeuralSpeech] waited %.1fs for the transcription model before loading", waited))
                }
            }
            let started = Date()
            try await LocalInferenceExecution.run(priority: .file) {
                // The ANE-resident int4 build: same quality, a third of the memory.
                let manager = Supertonic3Manager(vectorEstimator: .aneBucketed(.int4))
                try await manager.initialize()
                await self.setManager(manager)
            }
            log(String(format: "[NeuralSpeech] model ready in %.1fs", Date().timeIntervalSince(started)))
        }
        voiceLoaders += 1
        defer {
            voiceLoaders -= 1
            if voiceLoaders == 0, let burst = styleBurst {
                styleBurst = nil
                log(String(format: "[NeuralSpeech] %d voices loaded in %.1fs", burst.count, Date().timeIntervalSince(burst.started)))
            }
        }
        for voice in voices where styles[voice] == nil {
            try await loadStyle(voice)
        }
        guard let voice = voices.first else { return }
        try await warmUp.run(priority: .utility) {
            let started = Date()
            _ = try await self.synthesize("Да.", voice: voice)
            await self.markWarmed()
            log(String(format: "[NeuralSpeech] warm-up line synthesized in %.1fs", Date().timeIntervalSince(started)))
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    #if canImport(FluidAudio)
    /// Loads one voice style; a caller that arrives during the load waits for the same one.
    /// Two players load the voices together and take turns starting the next one, so
    /// `prepare` logs the whole burst once, when no caller is still loading voices, not each
    /// caller's share (2026-11-17: "5 voices loaded" twice for 10 voices).
    private func loadStyle(_ voice: Voice) async throws {
        if styles[voice] != nil { return }
        let task: Task<Supertonic3VoiceStyle, Error>
        if let existing = styleLoads[voice] {
            task = existing
        } else {
            guard let builtIn = Supertonic3Voice(name: voice.name) else {
                throw NSError(domain: "NeuralSpeech", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown voice \(voice.name)"])
            }
            task = Task(priority: .utility) { try await Supertonic3ResourceDownloader.loadVoiceStyle(builtIn) }
            styleLoads[voice] = task
            if styleBurst == nil { styleBurst = (Date(), 0) }
            styleBurst?.count += 1
        }
        do {
            styles[voice] = try await task.value
            styleLoads[voice] = nil
        } catch {
            styleLoads[voice] = nil
            throw error
        }
    }

    private func setManager(_ manager: Supertonic3Manager) { self.manager = manager }
    #endif
    private func markWarmed() { warmed = true }

    public var isReady: Bool {
        #if canImport(FluidAudio)
        warmed
        #else
        false
        #endif
    }

    /// Holds the gate set by `loadAfter`. Set synchronously at launch, before any player
    /// asks for the voice, so no actor hop can reorder the two.
    final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: (@Sendable () async -> Void)?
        func set(_ gate: @escaping @Sendable () async -> Void) {
            lock.lock(); defer { lock.unlock() }
            self.gate = gate
        }
        var current: (@Sendable () async -> Void)? {
            lock.lock(); defer { lock.unlock() }
            return gate
        }
    }

    /// 44.1 kHz mono samples of `text` read in Russian by `voice`.
    public func synthesize(_ text: String, voice: Voice, speed: Float = 1.05) async throws -> [Float] {
        #if canImport(FluidAudio)
        guard let manager, let style = styles[voice] else {
            throw NSError(domain: "NeuralSpeech", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Voice \(voice.name) is not loaded"])
        }
        return try await manager.synthesize(text: text, language: "ru", style: style, speed: speed).samples
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
}
