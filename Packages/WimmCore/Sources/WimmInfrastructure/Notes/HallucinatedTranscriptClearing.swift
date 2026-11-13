import Foundation
import WimmDomain

/// Turns a note whose stored transcript was made up over silence into the
/// shape the app gives a genuine no-speech recording: empty transcript,
/// `speechStatus = no_speech`, and no model-written card text.
///
/// Used only after a fresh transcription answered `[[NO_SPEECH]]` for a note
/// `audit-transcripts` flagged — `recordRunSuccess` deliberately never lets an
/// empty result replace earlier text, so the made-up text survives a retry.
/// Pure over the sidecar dictionary; the caller writes it through
/// `FileStore.mutateSidecar`.
public enum HallucinatedTranscriptClearing {
    public enum Outcome: Equatable, Sendable {
        case cleared(previousWords: Int)
        /// The user edited the card text by hand — never overwrite that.
        case skippedUserEdited
        case skippedAlreadyEmpty
    }

    /// Card fields a model wrote from the transcript.
    static let modelWrittenCardKeys: Set<String> = [
        "refined_text", "provider", "model_used", "agent_recommendation",
        "agent_reason", "processed_at",
    ]
    /// Top-level stamps that describe the analysis being removed.
    static let analysisStampKeys: Set<String> = ["analysisGlossary", "analysisPseudonymization"]
    /// Run fields of the hallucinating transcription that no longer apply.
    static let transcriptionRunKeys: Set<String> = ["raw", "agentRecommendation", "agentReason"]

    public static func clear(
        _ sidecar: inout [String: Any],
        reason: String,
        at date: Date = Date()
    ) -> Outcome {
        var transcription = sidecar["transcription"] as? [String: Any] ?? [:]
        let previous = ((transcription["transcript"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty else { return .skippedAlreadyEmpty }
        if var card = sidecar["noteCard"] as? [String: Any] {
            // A JSON `null` here means "never edited" (older cards write it).
            if let edited = card["refined_edited_at"], !(edited is NSNull) { return .skippedUserEdited }
            for key in modelWrittenCardKeys { card.removeValue(forKey: key) }
            card["title"] = ""
            card["summary"] = "No speech detected"
            sidecar["noteCard"] = card
        }
        for key in transcriptionRunKeys { transcription.removeValue(forKey: key) }
        transcription["transcript"] = ""
        transcription["speechStatus"] = TranscriptionSpeechStatus.noSpeech.rawValue
        transcription["hallucinationClearedAt"] = ISO8601.string(from: date)
        transcription["hallucinationClearReason"] = reason
        sidecar["transcription"] = transcription
        for key in analysisStampKeys { sidecar.removeValue(forKey: key) }
        sidecar["suspectedNoSpeech"] = true
        sidecar["suspectedNoSpeechReason"] = reason
        return .cleared(previousWords: TranscriptHealth.words(previous).count)
    }
}
