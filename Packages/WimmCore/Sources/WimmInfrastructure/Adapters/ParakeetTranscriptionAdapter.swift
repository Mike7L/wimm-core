import Foundation
import WimmDomain

/// On-device file transcription with NVIDIA Parakeet (FluidAudio, Core ML on the Neural Engine).
///
/// Selected by a hear-model identifier with the `parakeet:` prefix (`parakeet:ultra`). Measured
/// on 59 real Russian notes (docs/FluidAudio_Local_ASR_Diarization_Bakeoff.md): ~126× realtime on
/// an M1, median CER 0.09 against Gemini, and — unlike Gemini — it returns nothing on silence
/// instead of inventing a greeting. Ultra beat Redux on every clip, so it is the only variant
/// offered.
public enum ParakeetModel {
    public static let prefix = "parakeet:"
    public static let ultra = "parakeet:ultra"

    /// The variant named by a hear-model identifier, or nil when the identifier is not Parakeet.
    public static func variant(from identifier: String) -> String? {
        let lower = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        let variant = String(lower.dropFirst(prefix.count))
        return variant.isEmpty ? nil : variant
    }

    public static func isParakeet(_ identifier: String) -> Bool { variant(from: identifier) != nil }

    /// Parakeet, like Gemini, can invent text on a near-silent note (Wimm_2026-08-16_00-49-12_560B19E3,
    /// −79 dBFS median: "I'm not a very valid to get about the global…", confidence 0.49–0.59,
    /// 2–9 words a minute). Real speech in 65 measured notes never went below 0.79 confidence
    /// and 70 words a minute. Both conditions must hold, so quiet but real speech is not caught.
    public static func looksLikeSilence(confidence: Float, words: Int, audioSeconds: Double) -> Bool {
        guard audioSeconds > 0 else { return words == 0 }
        let wordsPerMinute = Double(words) / audioSeconds * 60
        return words == 0 || (confidence < 0.7 && wordsPerMinute < 20)
    }

    public struct TimedToken: Sendable, Equatable {
        public let token: String
        public let startTime: Double
        public let endTime: Double
        public let confidence: Float

        public init(token: String, startTime: Double, endTime: Double, confidence: Float) {
            self.token = token
            self.startTime = startTime
            self.endTime = endTime
            self.confidence = confidence
        }
    }

    /// Groups SentencePiece sub-word tokens (starting with `▁` or a leading space) into word
    /// timings, carrying the mean softmax confidence of each word's sub-word tokens.
    public static func timedWords(from tokens: [TimedToken]) -> [SpeakerTurns.Word] {
        var words: [SpeakerTurns.Word] = []
        var currentWord = ""
        var wordStart: Double = 0
        var wordEnd: Double = 0
        var confidenceSum: Float = 0
        var tokenCount: Int = 0

        func flush() {
            let trimmed = currentWord.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            let meanConfidence: Float? = tokenCount > 0
                ? max(0, min(1, confidenceSum / Float(tokenCount)))
                : nil
            words.append(SpeakerTurns.Word(
                text: trimmed, start: wordStart, end: wordEnd, confidence: meanConfidence))
        }

        for timing in tokens {
            let raw = timing.token
            if raw.isEmpty || raw == "<blank>" || raw == "<pad>" { continue }
            let startsWord = raw.hasPrefix("▁") || raw.hasPrefix(" ") || currentWord.isEmpty
            if startsWord && !currentWord.isEmpty {
                flush()
                currentWord = ""
                confidenceSum = 0
                tokenCount = 0
            }
            if startsWord {
                var stripped = raw
                while stripped.hasPrefix("▁") || stripped.hasPrefix(" ") {
                    stripped.removeFirst()
                }
                currentWord = stripped
                wordStart = timing.startTime
            } else {
                currentWord += raw
            }
            wordEnd = timing.endTime
            if timing.confidence.isFinite {
                confidenceSum += timing.confidence
                tokenCount += 1
            }
        }
        flush()
        return words
    }
}

/// A Parakeet result with what the caller needs to judge it.
public struct ParakeetTranscript: Sendable {
    public let text: String
    public let confidence: Float
    public let audioSeconds: Double
    /// Word timings, for matching words to speakers. Empty when the model gave none.
    public let timedWords: [SpeakerTurns.Word]

    public init(text: String, confidence: Float, audioSeconds: Double, timedWords: [SpeakerTurns.Word] = []) {
        self.text = text
        self.confidence = confidence
        self.audioSeconds = audioSeconds
        self.timedWords = timedWords
    }

    public var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    public var looksLikeSilence: Bool {
        ParakeetModel.looksLikeSilence(confidence: confidence, words: words, audioSeconds: audioSeconds)
    }
}

#if canImport(FluidAudio)
@preconcurrency import FluidAudio

public struct ParakeetTranscriptionAdapter: FileTranscriptionPort, Sendable {
    private let variant: String
    private let language: String

    /// - Parameters:
    ///   - modelIdentifier: `parakeet:ultra`.
    ///   - language: the app's transcription language ("Auto", "ru", "Russian", …). It only picks
    ///     the alphabet Parakeet may emit; "Auto" leaves the choice to the model.
    public init(modelIdentifier: String = ParakeetModel.ultra, language: String = "Auto") {
        self.variant = ParakeetModel.variant(from: modelIdentifier) ?? "ultra"
        self.language = language
    }

    /// Returns the transcript, or an empty string when the model heard no speech.
    public func transcribeFile(at fileURL: URL) async throws -> String {
        try await transcribe(at: fileURL).text
    }

    public func transcribe(at fileURL: URL) async throws -> ParakeetTranscript {
        try await transcribe(at: fileURL, priority: .file)
    }

    func transcribeForSpeakerBackfill(at fileURL: URL) async throws -> ParakeetTranscript {
        try await transcribe(at: fileURL, priority: .background)
    }

    private func transcribe(at fileURL: URL, priority: LocalInferenceScheduler.Priority) async throws -> ParakeetTranscript {
        try await LocalInferenceScheduler.shared.withPermit(priority: priority) {
            do {
                let result = try await transcribeFileWithPermit(at: fileURL)
                await LocalModelResources.touch("parakeet:\(variant)")
                return result
            } catch {
                await LocalModelResources.touch("parakeet:\(variant)")
                throw error
            }
        }
    }

    private func transcribeFileWithPermit(at fileURL: URL) async throws -> ParakeetTranscript {
        guard let version = Self.version(for: variant) else {
            throw NSError(domain: "ParakeetTranscriptionAdapter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unknown Parakeet variant: \(variant)"])
        }
        let manager = try await ParakeetManagerCache.shared.manager(for: version)
        try Task.checkCancellation()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            fileURL, decoderState: &state, language: Self.scriptLanguage(for: language))
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        log(String(format: "[Parakeet] %@ confidence=%.3f words=%d audio=%.1fs took=%.1fs",
                   fileURL.lastPathComponent, result.confidence,
                   text.split(whereSeparator: \.isWhitespace).count, result.duration, result.processingTime))
        // Costs nothing, but still belongs in the ledger, like WhisperKit.
        TranscriptionCostLog.local(
            engine: "parakeet/\(variant)",
            noteFile: fileURL.lastPathComponent,
            audioSeconds: result.duration,
            text: text)
        return ParakeetTranscript(
            text: text, confidence: result.confidence, audioSeconds: result.duration,
            timedWords: Self.timedWords(from: result))
    }

    /// Transcribes 16 kHz mono samples already in memory (the live preview). Not logged or
    /// metered per call: it runs every second while recording.
    public func transcribe(samples: [Float]) async throws -> ParakeetTranscript {
        try await LocalInferenceScheduler.shared.withPermit(priority: .live) {
            do {
                let result = try await transcribeSamplesWithPermit(samples)
                await LocalModelResources.touch("parakeet:\(variant)")
                return result
            } catch {
                await LocalModelResources.touch("parakeet:\(variant)")
                throw error
            }
        }
    }

    private func transcribeSamplesWithPermit(_ samples: [Float]) async throws -> ParakeetTranscript {
        guard let version = Self.version(for: variant) else {
            throw NSError(domain: "ParakeetTranscriptionAdapter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unknown Parakeet variant: \(variant)"])
        }
        let manager = try await ParakeetManagerCache.shared.manager(for: version)
        try Task.checkCancellation()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            samples, decoderState: &state, language: Self.scriptLanguage(for: language))
        return ParakeetTranscript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: result.confidence, audioSeconds: result.duration,
            timedWords: Self.timedWords(from: result))
    }

    static func timedWords(from result: ASRResult) -> [SpeakerTurns.Word] {
        let tokens = (result.tokenTimings ?? []).map {
            ParakeetModel.TimedToken(
                token: $0.token, startTime: $0.startTime, endTime: $0.endTime, confidence: $0.confidence)
        }
        return ParakeetModel.timedWords(from: tokens)
    }

    /// Downloads (~600 MB once) and compiles the model so the first note does not pay for it.
    public static func preload(
        modelIdentifier: String = ParakeetModel.ultra,
        onlyIfInstalled: Bool = false
    ) async throws {
        guard let version = version(for: ParakeetModel.variant(from: modelIdentifier) ?? "ultra") else { return }
        try await LocalInferenceScheduler.shared.withPermit(priority: .file) {
            if onlyIfInstalled {
                let directory = AsrModels.defaultCacheDirectory(for: version)
                guard AsrModels.modelsExist(at: directory, version: version) else { return }
            }
            _ = try await ParakeetManagerCache.shared.manager(for: version)
        }
    }

    static func version(for variant: String) -> AsrModelVersion? {
        switch variant {
        case "ultra": return .ultra
        case "v3": return .v3
        default: return nil
        }
    }

    /// The script filter suppresses wrong-alphabet tokens. Only set it when the user fixed the
    /// language: a German note forced to Cyrillic would be worse than an occasional stray word.
    static func scriptLanguage(for appLanguage: String) -> Language? {
        let lower = appLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("ru") || lower == "русский" { return .russian }
        if lower.hasPrefix("en") { return .english }
        if lower.hasPrefix("de") || lower == "german" || lower == "deutsch" { return .german }
        if lower.hasPrefix("uk") || lower == "ukrainian" { return .ukrainian }
        return nil
    }
}

/// One loaded `AsrManager` per variant for the life of the process: loading compiles the
/// encoder for the Neural Engine, which takes seconds warm and minutes on first launch.
actor ParakeetManagerCache {
    static let shared = ParakeetManagerCache()

    private var managers: [AsrModelVersion: AsrManager] = [:]
    private var loading: [AsrModelVersion: Task<AsrManager, Error>] = [:]

    private func unload(_ version: AsrModelVersion) async {
        guard loading[version] == nil else { return }
        let manager = managers.removeValue(forKey: version)
        await manager?.cleanup()
    }

    func manager(for version: AsrModelVersion) async throws -> AsrManager {
        if let manager = managers[version] {
            await LocalModelResources.used("parakeet:\(version)") { await self.unload(version) }
            return manager
        }
        if let task = loading[version] { return try await task.value }
        let task = Task { () throws -> AsrManager in
            // Unstructured loading tasks do not inherit the caller's executor preference.
            try await LocalInferenceExecution.run(priority: .file) {
                let models = try await AsrModels.downloadAndLoad(version: version)
                let manager = AsrManager(config: ASRConfig(
                    tdtConfig: TdtConfig(blankId: version.blankId),
                    encoderHiddenSize: version.encoderHiddenSize))
                try await manager.loadModels(models)
                return manager
            }
        }
        loading[version] = task
        defer { loading[version] = nil }
        let manager = try await task.value
        managers[version] = manager
        await LocalModelResources.used("parakeet:\(version)") { await self.unload(version) }
        return manager
    }
}

#else

public struct ParakeetTranscriptionAdapter: FileTranscriptionPort, Sendable {
    public init(modelIdentifier: String = ParakeetModel.ultra, language: String = "Auto") {}

    public func transcribeFile(at fileURL: URL) async throws -> String {
        try await transcribe(at: fileURL).text
    }

    public func transcribe(at fileURL: URL) async throws -> ParakeetTranscript {
        throw NSError(domain: "ParakeetTranscriptionAdapter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Parakeet unavailable in current build."])
    }

    public func transcribe(samples: [Float]) async throws -> ParakeetTranscript {
        throw NSError(domain: "ParakeetTranscriptionAdapter", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Parakeet unavailable in current build."])
    }

    public static func preload(
        modelIdentifier: String = ParakeetModel.ultra,
        onlyIfInstalled: Bool = false
    ) async throws {}
}

#endif
