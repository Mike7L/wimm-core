import Foundation
import WimmInfrastructure
import Combine
import WimmDomain
import WimmTranscription

/// Protocol for transcription service.
public protocol TranscriberProtocol: Sendable {
    func transcribe(
        file: URL,
        engine: EngineID,
        model: String,
        language: String,
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?,
        onPartial: (@Sendable (String, Bool) -> Void)?
    ) async -> TranscriptionResult

    func transcribe(
        file: URL,
        engine: EngineID,
        language: String,
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?,
        onPartial: (@Sendable (String, Bool) -> Void)?
    ) async -> TranscriptionResult
}

public extension TranscriberProtocol {
    func transcribe(
        file: URL,
        engine: EngineID,
        model: String,
        language: String,
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)?,
        onPartial: (@Sendable (String, Bool) -> Void)?
    ) async -> TranscriptionResult {
        await transcribe(file: file, engine: engine, language: language, progress: progress, onPartial: onPartial)
    }

    /// Preferred API for callers: resolve engine from the configured transcription model.
    func transcribe(
        file: URL,
        language: String = "Auto",
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)? = nil
    ) async -> TranscriptionResult {
        let model = Config.transcribeModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = ModelRouter.provider(for: model)
        let engine: EngineID = (provider == .openrouter) ? .openrouter : .gemini
        return await transcribe(file: file, engine: engine, language: language, progress: progress, onPartial: nil)
    }

    func transcribe(
        file: URL,
        engine: EngineID,
        language: String = "Auto",
        progress: (@Sendable (Double, Double?, TimeInterval) -> Void)? = nil
    ) async -> TranscriptionResult {
        return await transcribe(file: file, engine: engine, language: language, progress: progress, onPartial: nil)
    }
}

extension TranscriptionService: TranscriberProtocol {}
