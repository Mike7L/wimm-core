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
    private var warmed = false
    #endif
    private var loading: Task<Void, Error>?

    /// Loads the model and the voices and runs one short phrase, so the first real line
    /// does not pay for the Neural Engine compile. Safe to call repeatedly.
    public func prepare(voices: [Voice]) async throws {
        #if canImport(FluidAudio)
        if loading == nil {
            loading = Task {
                let started = Date()
                // The ANE-resident int4 build: same quality, a third of the memory.
                let manager = Supertonic3Manager(vectorEstimator: .aneBucketed(.int4))
                try await manager.initialize()
                self.manager = manager
                log(String(format: "[NeuralSpeech] model ready in %.1fs", Date().timeIntervalSince(started)))
            }
        }
        do {
            try await loading?.value
        } catch {
            loading = nil
            throw error
        }
        for voice in voices where styles[voice] == nil {
            guard let builtIn = Supertonic3Voice(name: voice.name) else {
                throw NSError(domain: "NeuralSpeech", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown voice \(voice.name)"])
            }
            styles[voice] = try await Supertonic3ResourceDownloader.loadVoiceStyle(builtIn)
        }
        if !warmed, let voice = voices.first {
            let started = Date()
            _ = try await synthesize("Да.", voice: voice)
            warmed = true
            log(String(format: "[NeuralSpeech] voices loaded and warmed in %.1fs", Date().timeIntervalSince(started)))
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    public var isReady: Bool {
        #if canImport(FluidAudio)
        warmed
        #else
        false
        #endif
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
