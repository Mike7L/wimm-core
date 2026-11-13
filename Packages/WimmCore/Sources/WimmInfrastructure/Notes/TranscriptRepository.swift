import Foundation
import WimmDomain

/// Handles transcript, OCR, and text content extraction.
public actor TranscriptRepository: TranscriptRepositoryProtocol {

    public init() {}

    public private(set) var sidecarReadCount = 0

    // MARK: - Transcripts

    public func transcriptText(for file: URL) -> String? {
        // The body by the shared resolver; a text note's body is its file.
        // Only spoken/typed text counts here, not a document extraction.
        let content = NoteContent.load(anchor: file, sidecar: metadata(for: file))
        switch content.bodySource {
        case .typedFile, .transcript, .legacyTranscript: return content.body
        case .documentText: return content.kind == .text ? content.body : nil
        case nil: return nil
        }
    }

    /// The on-device streaming hypothesis captured while recording, when one
    /// exists. Kept alongside the cloud transcript as secondary evidence for
    /// the refine pass; absent for imports and file-based notes, and while the
    /// realtime text is itself the transcript (an iPhone note no file run has
    /// replaced yet), since a second copy of the same text is no evidence.
    public func localTranscriptText(for file: URL) -> String? {
        guard let transcription = TranscriptRuns.transcription(fromSidecar: metadata(for: file)),
              !TranscriptRuns.isRealtimeCopy(transcription) else { return nil }
        return TranscriptRuns.realtime(in: transcription)
    }

    /// Returns the best available text representation for the given file.
    /// Audio prefers transcription metadata; documents prefer document.text / OCR metadata; attachments are a fallback.
    public func textOfRecord(for file: URL) -> String? {
        // Text and audio: the shared resolver's body. Other kinds keep this
        // method's evidence order (document.text, OCR, attachments, transcript)
        // — it differs from the resolver's and is an open question in the doc.
        let content = NoteContent.load(anchor: file, sidecar: metadata(for: file))
        if content.kind == .text || content.kind == .audio {
            return content.body
        }

        let meta = metadata(for: file)
        if let doc = meta["document"] as? [String: Any],
           let text = (doc["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        if let ocr = meta["ocr"] as? [String: Any],
           let text = (ocr["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }

        let attachmentText = attachments(for: file)
            .compactMap { $0.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !attachmentText.isEmpty {
            return attachmentText.joined(separator: "\n\n")
        }

        let fallback = transcriptText(for: file)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (fallback?.isEmpty == false) ? fallback : nil
    }

    // MARK: - Mutations

    public func updateTranscriptText(text: String, duration: Double, to file: URL) throws {
        let normalized = normalizeTranscript(text)
        upsertTranscript(
            normalized,
            duration: duration,
            to: file,
            clearsFailure: true,
            speechStatus: normalized.isEmpty ? nil : .speech
        )
    }

    public func writeFailurePlaceholder(duration: Double, file: URL, reasonLabel: String? = nil, baseMessage: String = "Transcription failed") {
        let suffix = reasonLabel.map { " (" + $0 + ")" } ?? ""
        let placeholder = normalizeTranscript(baseMessage + suffix)
        upsertTranscript(
            placeholder,
            duration: duration,
            to: file,
            clearsFailure: false,
            speechStatus: nil
        )
    }

    public func recordTranscriptionFailure(for file: URL, reason: CoreTranscriptionFailureReason, underlying: Error?) -> String {
        let label = failureReasonLabel(reason, underlying: underlying)
        persistTranscriptionFailure(file: file, reason: reason, underlying: underlying)
        return label
    }

    // MARK: - Private Helpers

    private func metadata(for file: URL) -> [String: Any] {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard let data = try? Data(contentsOf: metaURL) else { return [:] }
        sidecarReadCount += 1
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func attachments(for file: URL) -> [NoteAttachment] {
        let meta = metadata(for: file)
        guard let list = meta["attachments"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict -> NoteAttachment? in
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr),
                  let type = dict["type"] as? String else { return nil }
            return NoteAttachment(
                id: id,
                url: url,
                type: type,
                extractedText: dict["extractedText"] as? String ?? dict["ocrText"] as? String,
                extractionProvider: dict["extractionProvider"] as? String ?? dict["ocrProvider"] as? String,
                extractionModel: dict["extractionModel"] as? String ?? dict["ocrModel"] as? String
            )
        }
    }

    private func upsertTranscript(
        _ transcript: String,
        duration: Double,
        to file: URL,
        clearsFailure: Bool,
        speechStatus: TranscriptionSpeechStatus?
    ) {
        FileStore.mutateTranscription(
            for: file,
            removingMetadataKeys: clearsFailure
                ? ["transcriptionFailure", "transcriptionFailureDetails"] : []
        ) { transcription in
            if clearsFailure { archivePreviousRun(in: &transcription, replacingWith: transcript) }
            transcription["transcript"] = transcript
            if let speechStatus {
                transcription["speechStatus"] = speechStatus.rawValue
            } else {
                transcription.removeValue(forKey: "speechStatus")
            }
            if duration.isFinite, duration > 0 {
                transcription["audioDurationSec"] = duration
            }
            return true
        }
    }

    private func normalizeTranscript(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: " ,", with: ",")
        s = s.replacingOccurrences(of: " .", with: ".")
        return s
    }
}
