import Foundation
import WimmDomain

/// The three ways a note's audio gets written down, each kept in its own place
/// in the sidecar's `transcription` dictionary so none overwrites another:
///
/// - `realtime` — the live text captured while recording
///   (`transcription.localTranscript`; on old iPhone notes the whole
///   `transcription` value is that plain string);
/// - `local` — the latest on-device file run (Parakeet, WhisperKit, native);
/// - `cloud` — the latest cloud file run (Gemini, OpenRouter).
///
/// The file runs are not separate slots: the current run lives in
/// `transcription.transcript` (+ `provider`/`model`), the runs it replaced in
/// `transcription.previousRuns`. The latest local and cloud run are derived
/// from those two by provider, and the archive never evicts the newest run of
/// a kind (`archivePreviousRun`), so both stay addressable however often the
/// note is re-run with the other one.
public enum TranscriptKind: String, Sendable, CaseIterable {
    case realtime
    case local
    case cloud

    /// The kind of a file run, by the `provider` `recordRunSuccess` stamped.
    /// nil for providers that are neither (`test`, missing on very old runs).
    public static func ofProvider(_ provider: String?) -> TranscriptKind? {
        guard let p = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !p.isEmpty else { return nil }
        if localProviders.contains(p) || p.hasPrefix("apple") || p.contains("on-device") { return .local }
        if cloudProviders.contains(p) || p.hasPrefix("gemini") || p.hasPrefix("openrouter") { return .cloud }
        return nil
    }

    /// The kind a hear-model identifier transcribes with. Parakeet must be
    /// checked by prefix: `ModelRouter` files it under the Gemini fallback.
    public static func ofModel(_ model: String) -> TranscriptKind {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ParakeetModel.isParakeet(lower) || lower.hasPrefix("whisper:") || lower.hasPrefix("whisper/")
            || lower.hasPrefix("local/") || lower == "native" || lower.hasPrefix("apple")
            || lower == "vnrecognizetext" || lower == "vision" || lower == "pdfkit" {
            return .local
        }
        return .cloud
    }

    /// The hear model a "Transcribe again" of this kind runs, without touching
    /// the hear model in Settings: Parakeet for on-device; for cloud the
    /// configured hear model when it is a cloud one, else the default Gemini.
    /// nil for `realtime` — that text only exists while recording.
    public func retranscriptionModel(configured: String = Config.transcribeModel) -> String? {
        switch self {
        case .realtime: return nil
        case .local: return ParakeetModel.ultra
        case .cloud:
            return Self.ofModel(configured) == .cloud ? configured : ModelSelection.defaultGeminiModel
        }
    }

    private static let localProviders: Set<String> = [
        "parakeet", "whisperkit", "native", "local", "mlx", "vision", "pdfkit", "plain_text"
    ]
    private static let cloudProviders: Set<String> = ["gemini", "openrouter", "gemini-live"]
}

/// One stored file run: the current one or an archived one.
public struct TranscriptRun: Sendable, Equatable {
    public let text: String
    public let provider: String?
    public let model: String?
    public let startedAt: Date?
    /// True for `transcription.transcript`, false for an archived run.
    public let isCurrent: Bool
    /// Index into `previousRuns` for an archived run.
    public let archiveIndex: Int?

    public var kind: TranscriptKind? { TranscriptKind.ofProvider(provider) }
}

public enum TranscriptRuns {
    /// The `transcription` value of a sidecar as a dictionary. A plain string
    /// (what `RecordingMetadata` — the iPhone recorder — writes) is that
    /// device's live text: it is both the current transcript and the realtime
    /// one until a file run replaces the transcript.
    public static func transcription(fromSidecar metadata: [String: Any]) -> [String: Any]? {
        FileStore.transcriptionDictionary(from: metadata["transcription"])
    }

    /// The realtime text, if any.
    public static func realtime(in transcription: [String: Any]) -> String? {
        nonEmpty(transcription["localTranscript"])
    }

    /// The current run and every archived one, newest first.
    public static func runs(in transcription: [String: Any]) -> [TranscriptRun] {
        var result: [TranscriptRun] = []
        if let text = nonEmpty(transcription["transcript"]), !isRealtimeCopy(transcription) {
            result.append(TranscriptRun(
                text: text,
                provider: transcription["provider"] as? String,
                model: transcription["model"] as? String,
                startedAt: date(transcription["startedAt"]) ?? date(transcription["transcribedAt"]),
                isCurrent: true, archiveIndex: nil))
        }
        let archived = transcription[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
        for (index, run) in archived.enumerated().reversed() {
            guard let text = nonEmpty(run["transcript"]) ?? nonEmpty(run["text"]) else { continue }
            result.append(TranscriptRun(
                text: text,
                provider: run["provider"] as? String,
                model: run["model"] as? String,
                startedAt: date(run["startedAt"]) ?? date(run["transcribedAt"]) ?? date(run["replacedAt"]),
                isCurrent: false, archiveIndex: index))
        }
        return result
    }

    /// Reads the current and archived runs from an `ocr`, `document`, or attachment dictionary, newest first.
    public static func extractionRuns(
        in dict: [String: Any],
        textKey: String = "text",
        legacyTextKey: String? = nil,
        providerKey: String = "provider",
        legacyProviderKey: String? = nil,
        modelKey: String = "model",
        legacyModelKey: String? = nil,
        ignoreValue: String? = nil
    ) -> [TranscriptRun] {
        var result: [TranscriptRun] = []
        let currentText = nonEmpty(dict[textKey]) ?? legacyTextKey.flatMap { nonEmpty(dict[$0]) }
        if let text = currentText, text != ignoreValue {
            let provider = nonEmpty(dict[providerKey]) ?? legacyProviderKey.flatMap { nonEmpty(dict[$0]) }
            let model = nonEmpty(dict[modelKey]) ?? legacyModelKey.flatMap { nonEmpty(dict[$0]) }
            result.append(TranscriptRun(
                text: text,
                provider: provider,
                model: model,
                startedAt: date(dict["startedAt"]),
                isCurrent: true,
                archiveIndex: nil
            ))
        }
        let archived = dict[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
        for (index, run) in archived.enumerated().reversed() {
            guard let text = nonEmpty(run["text"]) ?? nonEmpty(run["transcript"]),
                  text != ignoreValue
            else { continue }
            result.append(TranscriptRun(
                text: text,
                provider: nonEmpty(run["provider"]),
                model: nonEmpty(run["model"]),
                startedAt: date(run["startedAt"]) ?? date(run["replacedAt"]),
                isCurrent: false,
                archiveIndex: index
            ))
        }
        return result
    }

    /// The newest run of `kind` — the current run when it is of that kind.
    public static func latest(_ kind: TranscriptKind, in transcription: [String: Any]) -> TranscriptRun? {
        guard kind != .realtime else { return nil }
        return runs(in: transcription).first { $0.kind == kind }
    }

    /// Whether a run has succeeded on this note: `recordRunSuccess` always
    /// stamps `speechStatus` (speech or noSpeech), a failure placeholder
    /// removes it, and the promoted iPhone string carries it too.
    public static func hasSuccessfulRun(_ transcription: [String: Any]) -> Bool {
        transcription["speechStatus"] is String
    }

    public static func hasSuccessfulRun(forNoteFile file: URL) -> Bool {
        let url = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcription = transcription(fromSidecar: json) else { return false }
        // Runs older than `speechStatus` count when they left a provider and
        // text and no failure marker came after them.
        return hasSuccessfulRun(transcription)
            || (transcription["provider"] is String && nonEmpty(transcription["transcript"]) != nil
                && json["transcriptionFailure"] == nil)
    }

    /// A `transcript` that is only the promoted live string (no file run has
    /// replaced it yet) is the realtime text, not a run of its own.
    static func isRealtimeCopy(_ transcription: [String: Any]) -> Bool {
        guard transcription["provider"] == nil,
              let transcript = nonEmpty(transcription["transcript"]),
              let realtime = nonEmpty(transcription["localTranscript"]) else { return false }
        return transcript == realtime
    }

    static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601.date(from: string)
    }
}
