import Foundation
import WimmDomain
import WimmInfrastructure
import AVFoundation

#if canImport(WhisperKit) && !WIMM_DISABLE_WHISPERKIT
@preconcurrency import WhisperKit
#endif

public enum WhisperModelStatus: Equatable, Sendable {
    case idle
    case downloading
    case loading
    case ready
    case failed(String)
}

public typealias WhisperStatusHandler = @Sendable (WhisperModelStatus) -> Void

public actor WhisperModelManager {
    public static let shared = WhisperModelManager()

    private var tasks: [String: Task<WhisperModelStatus, Never>] = [:]
    private var cache: [String: WhisperModelStatus] = [:]

    public func status(for modelIdentifier: String) -> WhisperModelStatus {
        cache[modelIdentifier] ?? .idle
    }

    public func preload(modelIdentifier: String, statusHandler: WhisperStatusHandler? = nil) async -> WhisperModelStatus {
        if let cached = cache[modelIdentifier] {
            statusHandler?(cached)
            if case .ready = cached { return cached }
        }
        if let task = tasks[modelIdentifier] {
            let result = await task.value
            statusHandler?(result)
            return result
        }
        let task = Task<WhisperModelStatus, Never> {
            do {
                try await WhisperOnDeviceTranscriber.preloadModel(modelIdentifier: modelIdentifier) { status in
                    Task { await self.updateStatus(status, for: modelIdentifier, handler: statusHandler) }
                }
                await self.updateStatus(.ready, for: modelIdentifier, handler: statusHandler)
                return .ready
            } catch {
                let failure = WhisperModelStatus.failed(error.localizedDescription)
                await self.updateStatus(failure, for: modelIdentifier, handler: statusHandler)
                return failure
            }
        }
        tasks[modelIdentifier] = task
        let result = await task.value
        tasks[modelIdentifier] = nil
        return result
    }

    private func updateStatus(_ status: WhisperModelStatus, for modelIdentifier: String, handler: WhisperStatusHandler?) async {
        cache[modelIdentifier] = status
        handler?(status)
    }
}

public struct WhisperOnDeviceTranscriber: Transcriber {
    let modelIdentifier: String
    let durationSeconds: Double?
    let progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?

    public init(modelIdentifier: String, durationSeconds: Double? = nil, progress: (@Sendable (Double, Double?, TimeInterval) -> Void)? = nil) {
        self.modelIdentifier = modelIdentifier
        self.durationSeconds = durationSeconds
        self.progress = progress
    }

    public func transcribe(file url: URL, language: String) async -> TranscriptionResult {
        #if canImport(WhisperKit) && !WIMM_DISABLE_WHISPERKIT
        if #available(macOS 13, *) {
            let modelName = Self.cleanModelName(from: modelIdentifier)
            guard !modelName.isEmpty else {
                return .failure(.notSupported, underlying: nil)
            }
            do {
                let text = try await WhisperPipelineCache.shared.transcribe(
                    fileURL: url,
                    model: modelName,
                    durationSeconds: durationSeconds,
                    progress: progress
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty
                    ? .failure(.empty, underlying: nil)
                    : .success(trimmed)
            } catch {
                return .failure(.unknown, underlying: error)
            }
        } else {
            return .failure(.notSupported, underlying: nil)
        }
        #else
        return .failure(.notSupported, underlying: nil)
        #endif
    }

    public static func cleanModelName(from raw: String) -> String {
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

    static func preloadModel(modelIdentifier: String, statusHandler: WhisperStatusHandler? = nil) async throws {
        #if canImport(WhisperKit) && !WIMM_DISABLE_WHISPERKIT
        guard #available(macOS 13, *) else {
            throw NSError(domain: "app.wimm.whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit requires macOS 13+"])
        }
        let modelName = cleanModelName(from: modelIdentifier)
        guard !modelName.isEmpty else {
            throw NSError(domain: "app.wimm.whisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Whisper model identifier"])
        }
        try await WhisperPipelineCache.shared.preload(model: modelName, statusHandler: statusHandler)
        #else
        throw NSError(domain: "app.wimm.whisper", code: 3, userInfo: [NSLocalizedDescriptionKey: "WhisperKit unavailable"])
        #endif
    }
}

#if canImport(WhisperKit) && canImport(AVFoundation) && !WIMM_DISABLE_WHISPERKIT
@available(macOS 13, *)
actor WhisperPipelineCache {
    static let shared = WhisperPipelineCache()

    private var cachedModel: String?
    private var cachedPipeline: WhisperKit?
    private var loadingTask: Task<WhisperKit, Error>? = nil

    func transcribe(
        fileURL: URL,
        model: String,
        durationSeconds: Double?,
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?
    ) async throws -> String {
        let pipeline = try await pipeline(for: model, statusHandler: nil)
        let bridge = ProgressBridge(durationSeconds: durationSeconds, handler: progress)
        
        let results = try await pipeline.transcribe(audioPath: fileURL.path, decodeOptions: nil) { _ in
            bridge.handle(fractionCompleted: pipeline.progress.fractionCompleted)
            return true
        }
        bridge.finish()
        guard let first = results.first else {
            throw NSError(domain: "WhisperKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "empty result"])
        }
        return first.text
    }

    func preload(model: String, statusHandler: WhisperStatusHandler?) async throws {
        _ = try await pipeline(for: model, statusHandler: statusHandler)
    }

    func pipeline(for model: String, statusHandler: WhisperStatusHandler?) async throws -> WhisperKit {
        if let cachedPipeline, cachedModel?.caseInsensitiveCompare(model) == .orderedSame {
            statusHandler?(.ready)
            return cachedPipeline
        }
        if let loadingTask {
            let kit = try await loadingTask.value
            return kit
        }
        let task = Task { [model] () throws -> WhisperKit in
            let config = try await Self.prepareConfig(for: model, statusHandler: statusHandler)
            return try await WhisperKit(config)
        }
        loadingTask = task
        do {
            let kit = try await task.value
            cachedPipeline = kit
            cachedModel = model
            loadingTask = nil
            statusHandler?(.ready)
            return kit
        } catch {
            loadingTask = nil
            throw error
        }
    }

    private static func prepareConfig(for model: String, statusHandler: WhisperStatusHandler?) async throws -> WhisperKitConfig {
        let env = ProcessInfo.processInfo.environment
        let repo = env["WIMM_WHISPER_REPO"]?.nonEmpty ?? "argmaxinc/whisperkit-coreml"
        let downloadBase = ensureDownloadBase(from: env)
        let token = tokenFromEnvironment(env)
        
        statusHandler?(.downloading)
        let downloadURL = try await WhisperKit.download(
            variant: model,
            downloadBase: downloadBase,
            from: repo,
            token: token
        )
        
        statusHandler?(.loading)
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

    private static func tokenFromEnvironment(_ env: [String: String]) -> String? {
        return env["WIMM_WHISPER_TOKEN"]?.nonEmpty ?? env["HF_TOKEN"]?.nonEmpty
    }

    private final class ProgressBridge: @unchecked Sendable {
        let started: Date = Date()
        let durationSeconds: Double?
        let handler: (@Sendable (Double, Double?, TimeInterval) -> Void)?
        private var lastReported: Double = 0

        init(durationSeconds: Double?, handler: (@Sendable (Double, Double?, TimeInterval) -> Void)?) {
            self.durationSeconds = durationSeconds
            self.handler = handler
        }

        func handle(fractionCompleted fraction: Double) {
            let clamped = max(lastReported, min(0.95, fraction))
            report(clamped)
        }

        func finish() {
            report(1.0)
        }

        private func report(_ pct: Double) {
            guard let handler else { return }
            let elapsed = Date().timeIntervalSince(started)
            let clamped = min(1.0, max(lastReported, pct))
            lastReported = clamped
            handler(clamped, nil, elapsed)
        }
    }
}
#endif

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
