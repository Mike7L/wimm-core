import Foundation
import WimmDomain

/// What an agent may learn about a note from its `.meta.json`, read-only:
/// duration, the speech verdict, device, and every text variant the
/// pipeline stored. The sidecar is never handed out whole — it can hold
/// clipboard text, window titles and failure details nobody asked for.
public struct RecallSidecar {
    let dict: [String: Any]

    init(_ dict: [String: Any]) {
        self.dict = dict
    }

    /// Reads the sidecar of `mediaURL`; nil when it is missing or unreadable.
    public static func load(forRecordingURL mediaURL: URL) -> (url: URL, data: Data, sidecar: RecallSidecar)? {
        let url = FileStore.metadataURL(forRecordingURL: mediaURL)
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (url, data, RecallSidecar(dict))
    }

    private var transcription: [String: Any]? { dict["transcription"] as? [String: Any] }
    private var card: [String: Any]? { dict["noteCard"] as? [String: Any] }
    private var origin: [String: Any]? { dict["origin"] as? [String: Any] }
    private var document: [String: Any]? { dict["document"] as? [String: Any] }
    var isAgentDiscussion: Bool { origin?["source"] as? String == "agent-discussion" }

    /// The recorder's `duration`, else what transcription or the silence gate measured.
    var duration: Double? {
        Self.number(dict["duration"])
            ?? Self.number(transcription?["audioDurationSec"])
            ?? Self.number(dict["streamingSkipDurationSec"])
    }

    /// The main transcript: `transcription.transcript`, or the legacy plain string.
    var transcript: String? {
        Self.text(transcription?["transcript"]) ?? Self.text(dict["transcription"])
    }

    /// The realtime text captured while recording, unless it is itself the
    /// transcript (the iPhone's plain-string form, printed as `transcript`).
    var localTranscript: String? { Self.text(transcription?["localTranscript"]) }

    /// The newest archived run of each kind the current run is not — what a
    /// re-transcription with the other engine left behind.
    var otherRuns: [TranscriptRun] {
        guard let transcription else { return [] }
        let current = TranscriptRuns.runs(in: transcription).first(where: \.isCurrent)?.kind
        return [TranscriptKind.local, .cloud].compactMap { kind in
            guard kind != current, let run = TranscriptRuns.latest(kind, in: transcription),
                  !run.isCurrent else { return nil }
            return run
        }
    }
    var transcriptionProvider: String? { Self.text(transcription?["provider"]) }
    var transcriptionModel: String? { Self.text(transcription?["model"]) }
    var transcribedAt: String? { Self.text(transcription?["startedAt"]) ?? Self.text(transcription?["transcribedAt"]) }
    var transcriptionKind: TranscriptKind? {
        // The old iPhone recorder stored its live transcript as a plain string.
        if dict["transcription"] is String { return .realtime }
        if let transcription, TranscriptRuns.isRealtimeCopy(transcription) { return .realtime }
        return TranscriptKind.ofProvider(transcriptionProvider) ?? transcriptionModel.map(TranscriptKind.ofModel)
    }

    static let unavailableQuality = #"{"status":"unknown","checks":"not_recorded"}"#

    /// A bounded, named-field projection of this exact run's stored diagnostics.
    /// Never inherits current-run confidence for an archived or realtime text.
    func qualitySummary(archiveIndex: Int? = nil) -> String {
        let run: [String: Any]?
        if let archiveIndex {
            let archived = transcription?["previousRuns"] as? [[String: Any]] ?? []
            run = archived.indices.contains(archiveIndex) ? archived[archiveIndex] : nil
        } else { run = transcription }
        guard let run else { return Self.unavailableQuality }
        let quality = run["quality"] as? [String: Any] ?? [:]
        var result: [String: Any] = [:]
        let names = ["loop", "silence", "density", "confidence", "word_confidence", "coverage"]
        let states: Set<String> = ["checked", "unavailable", "insufficient_data", "skipped_loop", "skipped_silence"]
        let storedChecks = quality["checks"] as? [String: String] ?? [:]
        let checks = Dictionary(uniqueKeysWithValues: names.compactMap { name -> (String, String)? in
            guard let state = storedChecks[name], states.contains(state) else { return nil }
            return (name, state)
        })
        let issues = (quality["issues"] as? [String] ?? []).prefix(12).filter {
            $0.count <= 80 && $0.range(of: #"^[a-z_]+:[a-z_]+$"#, options: .regularExpression) != nil
        }
        let status = !issues.isEmpty || quality["status"] as? String == "suspect" ? "suspect"
            : (checks.count == names.count && checks.values.allSatisfy { $0 == "checked" } ? "ok" : "unknown")
        result["status"] = status
        if status != "ok" {
            result["checks"] = checks.isEmpty ? "not_recorded" : checks as Any
        }
        if !issues.isEmpty { result["issues"] = Array(issues) }
        let zeroWhenHealthy: Set<String> = ["lowConfidenceWordShare", "unspokenSpeechSeconds", "maxUnspokenSpeechStretch", "repeated6GramShare"]
        for name in ["confidence", "p10Confidence", "lowConfidenceWordShare", "unspokenSpeechSeconds", "maxUnspokenSpeechStretch", "repeated6GramShare"] {
            if let value = (quality[name] ?? (name == "confidence" ? run[name] : nil)) as? NSNumber,
               value.doubleValue.isFinite {
                if status == "ok", zeroWhenHealthy.contains(name), value.doubleValue == 0 { continue }
                result[name] = Self.roundedNumber(value)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return Self.unavailableQuality }
        return text
    }

    private static func roundedNumber(_ number: NSNumber) -> NSNumber {
        let d = number.doubleValue
        guard d.isFinite else { return number }
        let rounded = (d * 1000).rounded() / 1000
        if rounded.rounded() == rounded { return NSNumber(value: Int(rounded)) }
        var s = String(format: "%.3f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return NSDecimalNumber(string: s)
    }

    /// Transcripts a later run replaced (`transcription.previousRuns`), oldest first.
    var previousRuns: [(transcript: String, source: String?, kind: TranscriptKind?, startedAt: String?, replacedAt: String?, quality: String)] {
        (transcription?["previousRuns"] as? [[String: Any]] ?? []).enumerated().compactMap { index, run in
            guard let text = Self.text(run["transcript"]) else { return nil }
            let provider = Self.text(run["provider"])
            let model = Self.text(run["model"])
            let kind = TranscriptKind.ofProvider(provider) ?? model.map(TranscriptKind.ofModel)
            return (text, Self.join(provider, model), kind,
                    Self.text(run["startedAt"]) ?? Self.text(run["transcribedAt"]), Self.text(run["replacedAt"]), qualitySummary(archiveIndex: index))
        }
    }

    var cardTitle: String? { Self.text(card?["title"]) }
    var cardSummary: String? { Self.text(card?["summary"]) }
    var refined: String? { Self.text(card?["refined_text"]) }
    var refinedEditedAt: String? { Self.text(card?["refined_edited_at"]) }
    /// Set only by a model-written NoteCard; fallback cards (the first words
    /// of the transcript) and typed notes have none.
    var processedAt: String? { Self.text(card?["processed_at"]) }

    var documentText: String? { Self.text(document?["text"]) }
    var documentSource: String? {
        Self.join(Self.text(document?["textProvider"]), Self.text(document?["textModel"]))
    }
    var previousDocumentRuns: [(text: String, source: String?, replacedAt: String?)] {
        Self.archivedExtractionRuns(document?["previousRuns"])
    }
    var ocrText: String? { Self.text((dict["ocr"] as? [String: Any])?["text"]) }
    var ocrSource: String? {
        let ocr = dict["ocr"] as? [String: Any]
        return Self.join(Self.text(ocr?["provider"]), Self.text(ocr?["model"]))
    }
    var previousOCRRuns: [(text: String, source: String?, replacedAt: String?)] {
        Self.archivedExtractionRuns((dict["ocr"] as? [String: Any])?["previousRuns"])
    }

    /// Attachment text in sidecar order: (type, text, provider/model, previousRuns,
    /// and the evening-journal question a spoken answer replies to).
    var attachments: [(index: Int, type: String, text: String, source: String?, previousRuns: [(text: String, source: String?, replacedAt: String?)], prompt: String?)] {
        (dict["attachments"] as? [[String: Any]] ?? []).enumerated().compactMap { index, a in
            guard let text = Self.text(a["extractedText"]) ?? Self.text(a["ocrText"]) else { return nil }
            let provider = Self.text(a["extractionProvider"]) ?? Self.text(a["ocrProvider"])
            let model = Self.text(a["extractionModel"]) ?? Self.text(a["ocrModel"])
            let previous = Self.archivedExtractionRuns(a["previousRuns"])
            return (index, Self.text(a["type"]) ?? "file", text, Self.join(provider, model), previous, Self.text(a["journalPrompt"]))
        }
    }

    private static func archivedExtractionRuns(_ raw: Any?) -> [(text: String, source: String?, replacedAt: String?)] {
        (raw as? [[String: Any]] ?? []).compactMap { run in
            guard let text = Self.text(run["text"]) ?? Self.text(run["transcript"]),
                  text != NoteAttachmentMedia.noSpeechText
            else { return nil }
            let source = Self.join(Self.text(run["provider"]), Self.text(run["model"]))
            return (text, source, Self.text(run["replacedAt"]))
        }
    }

    /// "iPhone" / "macOS".
    var platform: String? { Self.text(origin?["platform"]) }
    /// Hardware model, e.g. "iPhone15,2".
    var deviceModel: String? { Self.text(origin?["device"]) }

    /// Where the note came from when recorded inside a document or conversation workflow.
    public var originSource: String? { Self.text(origin?["source"]) }
    public var originSection: String? { Self.text(origin?["section"]) }
    public var originHeading: String? { Self.text(origin?["heading"]) }
    public var originQuote: String? { Self.text(origin?["quote"]) }
    public var conversationId: String? { Self.text(origin?["conversationId"]) }
    public var conversationFile: String? { Self.text(origin?["conversationFile"]) }
    public var conversationPrompt: String? { Self.text(origin?["prompt"]) }

    /// Links a recorded note to the conversation and document section it was spoken in,
    /// merging into `origin` through `FileStore.mutateSidecar` so device/platform keys stay intact.
    public static func linkConversation(
        forRecordingURL mediaURL: URL,
        source: String,
        doc: String? = nil,
        section: String? = nil,
        heading: String? = nil,
        conversationId: String? = nil,
        conversationFile: String? = nil,
        prompt: String? = nil
    ) throws {
        let sidecarURL = FileStore.metadataURL(forRecordingURL: mediaURL)
        try FileStore.mutateSidecar(at: sidecarURL) { metadata in
            var origin = metadata["origin"] as? [String: Any] ?? [:]
            origin["source"] = source
            if let doc = Self.text(doc) { origin["doc"] = doc }
            if let section = Self.text(section) { origin["section"] = section }
            if let heading = Self.text(heading) { origin["heading"] = heading }
            if let conversationId = Self.text(conversationId) { origin["conversationId"] = conversationId }
            if let conversationFile = Self.text(conversationFile) { origin["conversationFile"] = conversationFile }
            if let prompt = Self.text(prompt) { origin["prompt"] = prompt }
            metadata["origin"] = origin
            return true
        }
    }

    var syncUpdatedAt: String? { Self.text(dict["syncUpdatedAt"]) }
    var lastSaved: String? { Self.text(dict["lastSaved"]) }
    var skipReason: String? { Self.text(dict["streamingSkipReason"]) }
    var failureReason: String? {
        let failure = dict["transcriptionFailure"] as? [String: Any]
        return Self.text(failure?["reason"]) ?? Self.text(failure?["label"])
    }

    /// `speech` / `no_speech` / `skipped:<reason>` / `failed` for audio, nil otherwise.
    /// A model's no-speech verdict wins; a transcript counts as speech even
    /// when the live gate had skipped the recording earlier.
    func speech(isAudio: Bool) -> String? {
        guard isAudio else { return nil }
        if Self.text(transcription?["speechStatus"]) == TranscriptionSpeechStatus.noSpeech.rawValue {
            return "no_speech"
        }
        if let transcript {
            switch transcript.lowercased() {
            case "no speech detected": return "no_speech"
            case "transcription failed", "no text recognized": return "failed"
            default: return "speech"
            }
        }
        if let skipReason { return "skipped:\(skipReason)" }
        return "failed"
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func text(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

    static func join(_ provider: String?, _ model: String?) -> String? {
        let parts = [provider, model].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// Latest write to the note: its sidecar or the file itself (a typed
    /// note changes only the `.txt`). Matches what changes the sidecar hash.
    static func updated(forRecordingURL mediaURL: URL) -> Date? {
        [mediaURL, FileStore.metadataURL(forRecordingURL: mediaURL)]
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .max()
    }
}
