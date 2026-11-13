import Foundation
import WimmDomain

#if canImport(WhisperKit) && canImport(AVFoundation) && !WIMM_DISABLE_WHISPERKIT
@preconcurrency import WhisperKit
import AVFoundation

public struct WhisperKitTranscriptionAdapter: TranscriptionPort, Sendable {
    private let modelIdentifier: String

    public init(modelIdentifier: String = "base") {
        self.modelIdentifier = Self.cleanModelName(from: modelIdentifier)
    }

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Streaming capture is not supported for WhisperKit file adapter."])
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Capture stop is not supported for WhisperKit file adapter."])
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        guard #available(macOS 13, *) else {
            throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 2, userInfo: [NSLocalizedDescriptionKey: "WhisperKit requires macOS 13+"])
        }
        guard !modelIdentifier.isEmpty else {
            throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid Whisper model identifier"])
        }

        let text = try await WhisperPipelineCache.shared.transcribe(fileURL: fileURL, model: modelIdentifier)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 4, userInfo: [NSLocalizedDescriptionKey: "WhisperKit returned empty transcription"])
        }
        // Costs nothing, but still belongs in the ledger: without these minutes
        // there is no baseline to compare cloud spend against.
        TranscriptionCostLog.local(
            engine: "whisper/\(modelIdentifier)",
            noteFile: fileURL.lastPathComponent,
            audioSeconds: await GeminiTranscriptionAdapter.audioDurationSeconds(of: fileURL),
            text: trimmed)
        return trimmed
    }

    private static func cleanModelName(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("whisper:") {
            return String(trimmed.dropFirst("whisper:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lower.hasPrefix("whisper/") {
            return String(trimmed.dropFirst("whisper/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let allowed = Set([
            "tiny", "tiny.en", "base", "base.en", "small", "small.en",
            "medium", "medium.en", "large", "large-v2", "large-v3",
            "large-v3-turbo", "distil-large-v3"
        ])
        if allowed.contains(lower) { return trimmed }
        return ""
    }
}

@available(macOS 13, *)
actor WhisperPipelineCache {
    static let shared = WhisperPipelineCache()

    private var cachedModel: String?
    private var cachedPipeline: WhisperKit?
    private var loadingTask: Task<WhisperKit, Error>?

    func transcribe(fileURL: URL, model: String) async throws -> String {
        let pipeline = try await pipeline(for: model)
        let results = try await pipeline.transcribe(audioPath: fileURL.path, decodeOptions: nil) { _ in true }
        guard let first = results.first else {
            throw NSError(domain: "WhisperKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "empty result"])
        }
        return first.text
    }

    private func pipeline(for model: String) async throws -> WhisperKit {
        if let cachedPipeline, cachedModel?.caseInsensitiveCompare(model) == .orderedSame {
            return cachedPipeline
        }
        if let loadingTask {
            return try await loadingTask.value
        }

        let task = Task { [model] () throws -> WhisperKit in
            let config = try await Self.prepareConfig(for: model)
            return try await WhisperKit(config)
        }
        loadingTask = task

        do {
            let kit = try await task.value
            cachedPipeline = kit
            cachedModel = model
            loadingTask = nil
            return kit
        } catch {
            loadingTask = nil
            throw error
        }
    }

    private static func prepareConfig(for model: String) async throws -> WhisperKitConfig {
        let env = ProcessInfo.processInfo.environment
        let repo = env["WIMM_WHISPER_REPO"]?.nonEmpty ?? "argmaxinc/whisperkit-coreml"
        let downloadBase = ensureDownloadBase(from: env)
        let token = env["WIMM_WHISPER_TOKEN"]?.nonEmpty ?? env["HF_TOKEN"]?.nonEmpty

        let downloadURL = try await WhisperKit.download(
            variant: model,
            downloadBase: downloadBase,
            from: repo,
            token: token
        )

        return WhisperKitConfig(
            model: model,
            downloadBase: downloadBase,
            modelRepo: repo,
            modelToken: token,
            modelFolder: downloadURL.path,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndGPU,
                textDecoderCompute: .cpuAndGPU
            ),
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        )
    }

    private static func ensureDownloadBase(from env: [String: String]) -> URL? {
        if let custom = env["WIMM_WHISPER_CACHE_DIR"]?.nonEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WhisperKit", isDirectory: true) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

#else

public struct WhisperKitTranscriptionAdapter: TranscriptionPort, Sendable {
    public init(modelIdentifier: String = "base") {}

    public func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "WhisperKit is not included in this build. Use Parakeet, or rebuild with WIMM_ENABLE_WHISPERKIT=1."])
    }

    public func stopCapture() async throws -> (audioData: Data, finalText: String) {
        throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "WhisperKit is not included in this build. Use Parakeet, or rebuild with WIMM_ENABLE_WHISPERKIT=1."])
    }

    public func transcribeFile(at fileURL: URL) async throws -> String {
        throw NSError(domain: "WhisperKitTranscriptionAdapter", code: 3, userInfo: [NSLocalizedDescriptionKey: "WhisperKit is not included in this build. Use Parakeet, or rebuild with WIMM_ENABLE_WHISPERKIT=1."])
    }
}

#endif
