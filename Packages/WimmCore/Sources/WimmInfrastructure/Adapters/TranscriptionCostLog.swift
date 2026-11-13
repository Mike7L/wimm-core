import Foundation

/// One request/response pair in the unified event log for a transcription call.
///
/// The transcription adapters bypass `LLMJSONClient` entirely — they speak to
/// the API over raw `URLSession` — so they cannot inherit its logging. This is
/// the small shim that puts them in the same ledger, using the same attribute
/// keys, so `wimm-cli cost` sees one stream and not two.
///
/// On-device runs go through ``local(engine:noteFile:audioSeconds:)``: they cost
/// nothing, but they must still be recorded, otherwise there is no denominator
/// for "how much did staying on-device save".
struct TranscriptionCostLog: Sendable {
    private let model: String
    private let provider: String
    private let correlationId: UUID
    private let baseAttributes: [String: String]
    private let prompt: String

    init(
        model: String,
        provider: String = "gemini",
        engine: String = "cloud",
        noteFile: String?,
        audioSeconds: Double?,
        uploadBytes: Int?,
        uploadMode: String?,
        prompt: String,
        origin: String = "GeminiTranscriptionAdapter.transcribeFile"
    ) {
        self.model = model
        self.provider = provider
        self.prompt = prompt

        var attrs: [String: String] = [
            "requester": "TranscriptionAdapter",
            "request_kind": "transcription",
            "operation": LLMOperation.transcribe.rawValue,
            "engine": engine,
            "capability": ModelCapability.hear.rawValue,
        ]
        if let noteFile, !noteFile.isEmpty { attrs["note_file"] = noteFile }
        if let audioSeconds { attrs["audio_sec"] = String(format: "%.2f", audioSeconds) }
        if let uploadBytes { attrs["upload_bytes"] = String(uploadBytes) }
        if let uploadMode { attrs["upload_mode"] = uploadMode }
        self.baseAttributes = attrs

        self.correlationId = LLMLogger.shared.logRequest(
            model: model,
            provider: provider,
            origin: origin,
            attributes: attrs,
            system: nil,
            user: prompt,
            isStreaming: false
        )
    }

    func finish(text: String, usage: TokenUsage?) {
        var attrs = baseAttributes
        if let usage, !usage.isEmpty {
            attrs.merge(usage.logAttributes) { _, new in new }
        }
        attrs["transcript_chars"] = String(text.count)
        LLMLogger.shared.logResponse(
            model: model,
            provider: provider,
            origin: "TranscriptionCostLog.finish",
            attributes: attrs,
            system: nil,
            user: prompt,
            response: text,
            isStreaming: false,
            correlationId: correlationId
        )
    }

    func fail(_ error: Error) {
        LLMLogger.shared.logResponse(
            model: model,
            provider: provider,
            origin: "TranscriptionCostLog.fail",
            attributes: baseAttributes,
            system: nil,
            user: prompt,
            response: nil,
            error: error.localizedDescription,
            isStreaming: false,
            correlationId: correlationId
        )
    }

    /// Records an on-device transcription: no tokens, no money, but it belongs
    /// in the ledger so the free tier can be compared against the paid one.
    static func local(engine: String, noteFile: String?, audioSeconds: Double?, text: String) {
        let log = TranscriptionCostLog(
            model: engine,
            provider: "on-device",
            engine: "on-device",
            noteFile: noteFile,
            audioSeconds: audioSeconds,
            uploadBytes: nil,
            uploadMode: nil,
            prompt: "",
            origin: "TranscriptionCostLog.local"
        )
        log.finish(text: text, usage: nil)
    }
}

extension TranscriptionCostLog {
    /// Convenience for the Gemini adapter, which always uses the cloud engine.
    init(
        model: String,
        noteFile: String?,
        audioSeconds: Double?,
        uploadBytes: Int,
        uploadMode: String,
        prompt: String
    ) {
        self.init(
            model: model,
            provider: "gemini",
            engine: "cloud",
            noteFile: noteFile,
            audioSeconds: audioSeconds,
            uploadBytes: uploadBytes,
            uploadMode: uploadMode,
            prompt: prompt
        )
    }
}
