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
