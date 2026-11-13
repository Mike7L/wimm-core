import Foundation
import WimmDomain
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public enum TranscriptionEngine: String, Sendable {
    case native
    case gemini
    case geminiLive = "gemini-live"
    case openrouter
    case whisper
    case mock

    public static func fromEnvironment(_ env: [String: String]) -> TranscriptionEngine {
        let legacyKey = "MEM" + "ARIO_TRANSCRIBER"
        let raw = (
            env["WIMM_TRANSCRIBER"]
            ?? env["WIMM_TRANSCRIBE_ENGINE"]
            ?? env[legacyKey]
        )?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "native"
        return TranscriptionEngine(rawValue: raw) ?? .native
    }
}

public enum TranscriptionAdapterFactory {
    public static func make(
        engine: TranscriptionEngine,
        environment: [String: String],
        mockFactory: @autoclosure () -> TranscriptionPort
    ) -> TranscriptionPort {
        let geminiModel = environment["WIMM_GEMINI_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? environment["GEMINI_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? environment["GEMINI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? DefaultModels.gemini
        let geminiLiveModel = environment["WIMM_GEMINI_LIVE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? environment["GEMINI_LIVE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "gemini-3.1-flash-live-preview"
        let liveAudioSource = makeLiveAudioSource(environment: environment)
        let liveTransport = makeGeminiLiveTransport(environment: environment)

        switch engine {
        case .mock:
            print("Using MOCK Transcription Adapter (WIMM_TRANSCRIBER=mock).")
            return mockFactory()
        case .gemini:
            guard let apiKey = environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
                print("No GEMINI_API_KEY found. Falling back to Mock Transcription.")
                return mockFactory()
            }
            print("Using GEMINI HYBRID Transcription Adapter (live=native, final/file=Gemini, model=\(geminiModel)).")
            let streamingAdapter = makeHybridStreamingAdapter(environment: environment, liveAudioSource: liveAudioSource)
            let batchAdapter = makeGeminiBatchAdapter(
                environment: environment,
                apiKey: apiKey,
                modelName: geminiModel
            )
            return HybridGeminiTranscriptionAdapter(
                apiKey: apiKey,
                modelName: geminiModel,
                streaming: streamingAdapter,
                batch: batchAdapter
            )
        case .geminiLive:
            guard let apiKey = environment["GEMINI_API_KEY"], !apiKey.isEmpty else {
                print("No GEMINI_API_KEY found. Falling back to Mock Transcription.")
                return mockFactory()
            }
            print("Using GEMINI LIVE Transcription Adapter (model=\(geminiLiveModel)).")
            return GeminiLiveTranscriptionAdapter(
                apiKey: apiKey,
                modelName: geminiLiveModel,
                audioSource: liveAudioSource,
                transport: liveTransport
            )
        case .openrouter:
            guard let apiKey = environment["OPENROUTER_API_KEY"], !apiKey.isEmpty else {
                print("No OPENROUTER_API_KEY found. Falling back to Mock Transcription.")
                return mockFactory()
            }
            let model = environment["WIMM_OPENROUTER_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? environment["OPENROUTER_TRANSCRIBE_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? environment["OPENROUTER_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelName = (model?.isEmpty == false) ? model! : DefaultModels.openRouterTranscription
            print("Using OPENROUTER Transcription Adapter (model=\(modelName)).")
            return OpenRouterTranscriptionAdapter(apiKey: apiKey, modelName: modelName)
        case .whisper:
            let model = environment["WIMM_WHISPER_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            let modelIdentifier = (model?.isEmpty == false) ? model! : "base"
            print("Using WHISPER Transcription Adapter (model=\(modelIdentifier)).")
            return WhisperKitTranscriptionAdapter(modelIdentifier: modelIdentifier)
        case .native:
            print("Using NATIVE Transcription Adapter.")
            return NativeSpeechAdapter(audioSource: liveAudioSource)
        }
    }

    private static func makeLiveAudioSource(environment: [String: String]) -> LiveAudioSource {
        let mode = environment["WIMM_AUDIO_SOURCE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "microphone"

        guard mode == "fixture" else {
            return MicrophoneAudioSource()
        }

        guard
            let path = environment["WIMM_AUDIO_FIXTURE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty
        else {
            print("WIMM_AUDIO_SOURCE=fixture but WIMM_AUDIO_FIXTURE is missing. Falling back to microphone.")
            return MicrophoneAudioSource()
        }

        let chunkFrames = UInt32(environment["WIMM_AUDIO_FIXTURE_CHUNK_FRAMES"] ?? "") ?? 1024
        let delayMs = UInt64(environment["WIMM_AUDIO_FIXTURE_DELAY_MS"] ?? "") ?? 40
        print("Using FIXTURE audio source (\(URL(fileURLWithPath: path).lastPathComponent), chunk=\(chunkFrames), delayMs=\(delayMs)).")
        return FixtureAudioSource(
            fileURL: URL(fileURLWithPath: path),
            chunkFrameCount: AVAudioFrameCount(chunkFrames),
            interChunkDelayNanoseconds: delayMs * 1_000_000
        )
    }

    private static func makeGeminiLiveTransport(environment: [String: String]) -> GeminiLiveTransport {
        let mode = environment["WIMM_GEMINI_LIVE_TRANSPORT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "urlsession"

        guard mode == "recorded" else {
            return URLSessionGeminiLiveTransport()
        }

        guard
            let path = environment["WIMM_GEMINI_LIVE_SCENARIO"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !path.isEmpty,
            let transport = try? RecordedGeminiLiveTransport(fileURL: URL(fileURLWithPath: path))
        else {
            print("WIMM_GEMINI_LIVE_TRANSPORT=recorded but scenario is unavailable. Falling back to URLSession transport.")
            return URLSessionGeminiLiveTransport()
        }

        print("Using RECORDED Gemini Live transport (\(URL(fileURLWithPath: path).lastPathComponent)).")
        return transport
    }

    private static func makeHybridStreamingAdapter(
        environment: [String: String],
        liveAudioSource: LiveAudioSource
    ) -> TranscriptionPort {
        let mode = environment["WIMM_STREAMING_TRANSCRIBER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "native"

        guard mode == "recorded" else {
            return NativeSpeechAdapter(audioSource: liveAudioSource)
        }

        guard
            let scenarioPath = environment["WIMM_STREAMING_TRANSCRIBE_SCENARIO"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !scenarioPath.isEmpty
        else {
            print("WIMM_STREAMING_TRANSCRIBER=recorded but scenario is unavailable. Falling back to native speech.")
            return NativeSpeechAdapter(audioSource: liveAudioSource)
        }

        let audioPath = environment["WIMM_AUDIO_FIXTURE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let adapter = try? RecordedStreamingTranscriptionAdapter(
            scenarioFileURL: URL(fileURLWithPath: scenarioPath),
            audioFileURL: (audioPath?.isEmpty == false) ? URL(fileURLWithPath: audioPath!) : nil
        )

        guard let adapter else {
            print("Failed to load recorded streaming scenario. Falling back to native speech.")
            return NativeSpeechAdapter(audioSource: liveAudioSource)
        }

        print("Using RECORDED streaming transcriber (\(URL(fileURLWithPath: scenarioPath).lastPathComponent)).")
        return adapter
    }

    private static func makeGeminiBatchAdapter(
        environment: [String: String],
        apiKey: String,
        modelName: String
    ) -> any FileTranscriptionPort {
        guard
            let scenarioPath = environment["WIMM_GEMINI_TRANSCRIBE_SCENARIO"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !scenarioPath.isEmpty,
            let adapter = try? RecordedBatchTranscriptionAdapter(scenarioFileURL: URL(fileURLWithPath: scenarioPath))
        else {
            return GeminiTranscriptionAdapter(apiKey: apiKey, modelName: modelName)
        }

        print("Using RECORDED Gemini batch transcription (\(URL(fileURLWithPath: scenarioPath).lastPathComponent)).")
        return adapter
    }
}
