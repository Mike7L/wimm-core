import Foundation
import WimmDomain

let transcriptionRunScopedKeys: Set<String> = [
    "provider", "model", "startedAt", "elapsedMs", "raw",
    "agentRecommendation", "agentReason", "confidence", "quality"
]
/// Derived from a run but written after it (Parakeet word timings + diarization): a later run
/// must not inherit a speaker split of text it replaced, nor the backfill's "do not retry" marker.
let transcriptionDerivedKeys: Set<String> = ["speakerTurns", "speakerTurnsSkipped", "speechClassification"]
let transcriptionContentKeys: Set<String> = [
    "transcript", "audioDurationSec", "speechStatus"
]

/// Kept independent from the category union so a regression test catches a
/// writer field added without an explicit lifecycle decision.
let transcriptionFieldsWrittenByRunSuccess: Set<String> = [
    "provider", "model", "startedAt", "elapsedMs", "raw",
    "agentRecommendation", "agentReason", "confidence", "quality",
    "transcript", "audioDurationSec", "speechStatus"
]

// Persist successful transcription metadata for a given recording file.
// Stores provider/model, timestamps, elapsed, transcript text, and a trimmed raw response payload (if available).
public func recordRunSuccess(
    file: URL,
    provider: String,
    model: String,
    audioDuration: Double?,
    startedAt: Date,
    elapsedSeconds: Double,
    transcript: String,
    speechStatus: TranscriptionSpeechStatus,
    rawResponse: String?,
    agentRecommendation: String? = nil,
    agentReason: String? = nil,
    confidence: Float? = nil,
    timedWords: [SpeakerTurns.Word] = []
) {
    // An `_Attach_` file has no sidecar of its own: `FileStore.metadataURL`
    // strips the suffix and resolves to the *parent* note's sidecar, so writing
    // here would replace the note's main transcript with the attachment's text.
    // An attachment's transcript belongs on its `NoteAttachment.extractedText`,
    // which TranscriptionModelHandler writes.
    guard !FileStore.isAttachmentFile(file) else { return }

    let normalizedTranscript: String
    switch speechStatus {
    case .speech:
        normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            log("recordRunSuccess: rejected empty transcript marked as speech for \(file.lastPathComponent)")
            return
        }
    case .noSpeech:
        normalizedTranscript = ""
    }

    let iso = ISO8601.string(from: startedAt)
    // Trim raw to avoid massive .meta.json files (keep first 32 KB)
    var raw = rawResponse ?? ""
    if raw.count > 32_000 { raw = String(raw.prefix(31_900)) + "…" }
    var payload: [String: Any] = [
        "provider": provider,
        "model": model,
        "startedAt": iso,
        "elapsedMs": Int(elapsedSeconds * 1000),
        "transcript": normalizedTranscript,
        "speechStatus": speechStatus.rawValue
    ]
    if let d = audioDuration, d.isFinite { payload["audioDurationSec"] = d }
    if let c = confidence, c.isFinite {
        payload["confidence"] = (Double(c) * 1000).rounded() / 1000
    }
    if let agentRecommendation, !agentRecommendation.isEmpty {
        payload["agentRecommendation"] = agentRecommendation
    }
    if let agentReason, !agentReason.isEmpty {
        payload["agentReason"] = agentReason
    }
    if !raw.isEmpty { payload["raw"] = raw }

    let isAudio = DefaultFileStore.shared.supportedAudioExtensions.contains(file.pathExtension.lowercased())
    let audioProfile: TranscriptHealth.AudioProfile? = (speechStatus == .speech && isAudio)
        ? TranscriptHealth.profile(of: file)
        : nil

    FileStore.mutateTranscription(
        for: file,
        removingMetadataKeys: ["transcriptionFailure", "transcriptionFailureDetails"]
    ) { existing in
        // Never let an empty re-transcription clobber real text. This branch is
        // deliberately a no-op, including leaving failure markers intact: an
        // empty result after prior text is suspicious, not a successful repair.
        if speechStatus == .noSpeech,
           let prior = (existing["transcript"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !prior.isEmpty {
            return false
        }

        archivePreviousRun(in: &existing, replacingWith: normalizedTranscript)

        let localWords = (existing["localTranscript"] as? String).map {
            TranscriptHealth.words($0).count
        }

        // Unknown keys and explicitly durable fields survive. Every field owned
        // by a run is reset first so omitted raw/agent data cannot go stale.
        for key in transcriptionRunScopedKeys.union(transcriptionContentKeys).union(transcriptionDerivedKeys) {
            existing.removeValue(forKey: key)
        }
        for (key, value) in payload {
            existing[key] = value
        }
        if speechStatus == .speech {
            let quality = TranscriptHealth.evaluate(
                text: normalizedTranscript,
                profile: audioProfile,
                confidence: confidence,
                timedWords: timedWords,
                sentAudioSeconds: audioDuration,
                localWordCount: localWords
            )
            existing["quality"] = quality.sidecarDictionary
        }
        return true
    }
}

/// Durable key under `transcription`: earlier runs a re-transcription replaced,
/// newest last. Not run-scoped, so a new run keeps the archive it extends.
let transcriptionPreviousRunsKey = "previousRuns"
/// Enough to compare a few models against each other without letting a note
/// that is re-run in a loop grow its sidecar without bound.
let transcriptionPreviousRunsLimit = 8

/// Moves the transcript a new run is about to replace into
/// `transcription.previousRuns`, so re-transcribing with another model never
/// destroys the earlier text. A run that reproduces the stored text, an empty
/// stored transcript, or one that is only the realtime text promoted from the
/// iPhone's plain string (it stays in `localTranscript`) archives nothing.
func archivePreviousRun(in transcription: inout [String: Any], replacingWith newTranscript: String) {
    guard let prior = (transcription["transcript"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !prior.isEmpty,
          prior != newTranscript.trimmingCharacters(in: .whitespacesAndNewlines),
          !TranscriptRuns.isRealtimeCopy(transcription) else { return }

    var entry: [String: Any] = [
        "transcript": prior,
        "replacedAt": ISO8601.string(from: Date())
    ]
    for key in ["provider", "model", "startedAt", "speechStatus"] {
        if let value = transcription[key] as? String { entry[key] = value }
    }
    if let confidence = transcription["confidence"] as? NSNumber {
        entry["confidence"] = confidence.doubleValue
    }
    if let quality = transcription["quality"] as? [String: Any] {
        entry["quality"] = quality
    }

    var runs = transcription[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
    runs.append(entry)
    trimPreviousRuns(&runs)
    transcription[transcriptionPreviousRunsKey] = runs
}

/// Moves the OCR / document / attachment text a new run is about to replace into
/// `previousRuns` on that dictionary (`ocr.previousRuns`, `document.previousRuns`,
/// `attachments[i].previousRuns`), using the same 8-run cap and local/cloud kind
/// protection as audio transcriptions so re-running OCR never destroys earlier text.
public func archivePreviousExtractionRun(
    in dictionary: inout [String: Any],
    replacingWith newText: String,
    textKey: String = "text",
    legacyTextKey: String? = nil,
    providerKey: String = "provider",
    legacyProviderKey: String? = nil,
    modelKey: String = "model",
    legacyModelKey: String? = nil,
    ignoreValue: String? = nil
) {
    let rawPrior = (dictionary[textKey] as? String)
        ?? (legacyTextKey.flatMap { dictionary[$0] as? String })
    guard let prior = rawPrior?.trimmingCharacters(in: .whitespacesAndNewlines),
          !prior.isEmpty,
          prior != ignoreValue,
          prior != newText.trimmingCharacters(in: .whitespacesAndNewlines)
    else { return }

    var entry: [String: Any] = [
        "text": prior,
        "replacedAt": ISO8601.string(from: Date())
    ]
    if let provider = ((dictionary[providerKey] as? String)
        ?? (legacyProviderKey.flatMap { dictionary[$0] as? String }))?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !provider.isEmpty {
        entry["provider"] = provider
    }
    if let model = ((dictionary[modelKey] as? String)
        ?? (legacyModelKey.flatMap { dictionary[$0] as? String }))?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !model.isEmpty {
        entry["model"] = model
    }
    if let startedAt = (dictionary["startedAt"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !startedAt.isEmpty {
        entry["startedAt"] = startedAt
    }

    var runs = dictionary[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
    runs.append(entry)
    trimPreviousRuns(&runs)
    dictionary[transcriptionPreviousRunsKey] = runs
}

/// Drops the oldest archived runs down to the limit, but never the newest
/// archived run of each kind (local / cloud): ten cloud re-runs must not push
/// the only Parakeet text out of the note.
func trimPreviousRuns(_ runs: inout [[String: Any]]) {
    while runs.count > transcriptionPreviousRunsLimit {
        var newestOfKind: [TranscriptKind: Int] = [:]
        for (index, run) in runs.enumerated() {
            if let kind = TranscriptKind.ofProvider(run["provider"] as? String) {
                newestOfKind[kind] = index
            }
        }
        let protected = Set(newestOfKind.values)
        guard let victim = runs.indices.first(where: { !protected.contains($0) }) else { break }
        runs.remove(at: victim)
    }
}
