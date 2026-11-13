#if os(iOS)
import Foundation
import WimmDomain
import WimmInfrastructure
import WimmTranscription

/// Why a manual re-run on the phone did not start or did not finish.
enum NoteReprocessingError: LocalizedError, Equatable {
    case missingKey(LLMCfg.Provider)
    case notAudio
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(.openrouter): return L10n.iOS.Reprocess.missingOpenRouterKey
        case .missingKey: return L10n.iOS.Reprocess.missingGeminiKey
        case .notAudio: return L10n.iOS.Reprocess.notAudio
        case .transcriptionFailed(let reason): return L10n.iOS.Reprocess.transcriptionFailed(reason)
        }
    }

    /// Provider errors arrive as whole JSON bodies; an alert needs the one
    /// human sentence inside (`"message": "API key not valid…"`).
    static func providerMessage(from raw: String) -> String {
        if let range = raw.range(of: #""message"\s*:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) {
            let match = String(raw[range])
            if let start = match.range(of: #":\s*""#, options: .regularExpression) {
                return String(match[start.upperBound...].dropLast())
                    .replacingOccurrences(of: #"\""#, with: "\"")
            }
        }
        let flat = raw.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 200 ? String(flat.prefix(200)) + "…" : flat
    }
}

/// Whether a real key is configured. The rotators never come back empty:
/// with nothing configured `loadAPIKeys` returns its `REPLACE_WITH_…`
/// placeholder, which would otherwise count as a key and reach the provider
/// as "API key not valid".
enum ConfiguredKeys {
    static func gemini() async -> Bool {
        await APIKeyRotator.shared.reload()
        return containsRealKey(await APIKeyRotator.shared.allKeys())
    }

    static func openRouter() async -> Bool {
        await OpenRouterKeyRotator.shared.reload()
        return containsRealKey(await OpenRouterKeyRotator.shared.allKeys())
    }

    static func containsRealKey(_ keys: [String]) -> Bool {
        keys.contains { !$0.uppercased().hasPrefix("REPLACE_WITH_") }
    }
}

/// Manual re-transcription using the models chosen in Settings. Runs on AppState so a job
/// survives leaving the note, and the result reaches the Mac through the
/// regular sync (a rewritten sidecar makes the bundle newer).
extension AppState {
    func isReprocessing(_ url: URL) -> Bool {
        reprocessingURLs.contains(url)
    }

    /// Re-transcribes the audio and publishes the new text.
    /// `model` overrides the hear model for this run only; the run it
    /// replaces stays in the sidecar (`TranscriptKind`), so the note keeps
    /// its realtime, on-device and cloud texts side by side.
    func retranscribe(_ url: URL, model: String? = nil) async throws {
        guard FileStore.isAudioFile(url) else { throw NoteReprocessingError.notAudio }
        try await requireKey(for: model ?? Config.transcribeModel)
        if let model, TranscriptKind.ofModel(model) == .cloud, PrivateMode.isEnabled {
            throw NoteReprocessingError.transcriptionFailed(L10n.PrivateMode.transcriptionRefused)
        }
        guard beginReprocessing(url) else { return }
        defer { reprocessingURLs.remove(url) }

        if let model {
            _ = try await runTranscription(of: url, model: model)
        } else {
            _ = try await runTranscription(of: url)
        }
        await finishReprocessing(url)
    }

    // MARK: - Queue

    func perform(_ kind: ProcessingJobKind, url: URL) async throws -> ProcessingOutcome {
        switch kind {
        case .transcribe:
            try await retranscribe(url)
        case .transcribeLocal:
            try await retranscribe(url, model: TranscriptKind.local.retranscriptionModel())
        case .transcribeCloud:
            try await retranscribe(url, model: TranscriptKind.cloud.retranscriptionModel())
        case .analyze:
            // Jobs persisted by older versions still decode.
            return .skipped
        case .auto:
            guard await needsTranscription(for: url) else { return .skipped }
            try await retranscribe(url)
        }
        return .done
    }

    func needsTranscription(for url: URL) async -> Bool {
        guard FileStore.isAudioFile(url) else { return false }
        let run = await repository.metadata(for: url)[MetadataKey.transcription.rawValue] as? [String: Any]
        let provider = (run?["provider"] as? String)?.lowercased() ?? ""
        return Self.isOnDeviceProvider(provider)
    }

    nonisolated static func isOnDeviceProvider(_ provider: String) -> Bool {
        provider.isEmpty || provider == "native" || provider.contains("on-device") || provider.hasPrefix("apple")
    }

    /// Notes worth an `.auto` job, newest first, without the ones already queued.
    func unprocessedNotes() async -> [URL] {
        var result: [URL] = []
        for recording in recordings where !processingQueue.isActive(recording.fileURL) {
            if await needsTranscription(for: recording.fileURL) { result.append(recording.fileURL) }
        }
        return result
    }

    private func beginReprocessing(_ url: URL) -> Bool {
        reprocessingURLs.insert(url).inserted
    }

    private func finishReprocessing(_ url: URL) async {
        await publishRecording(at: url)
        scheduleRecordingSync(for: url)
    }

    private func requireKey(for model: String) async throws {
        guard await hasKey(for: model) else {
            throw NoteReprocessingError.missingKey(ModelRouter.provider(for: model))
        }
    }
}
#endif
