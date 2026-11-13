import Foundation
import WimmDomain

/// Stateless note factory extracted from the former NotesService.
/// All methods are static so they can be called without instantiation.
public enum NoteBuilder {

    // MARK: - Build

    /// Constructs a WimmCore.Note from a file URL and its associated repositories.
    ///
    /// This is the canonical note-building routine. All dependencies are passed as
    /// parameters so no actor isolation is required.
    public static func build(
        file: URL,
        index: Int,
        metaRepo: MetadataRepositoryProtocol,
        transcriptRepo: any TranscriptRepositoryProtocol,
        directoryIndex: RecordingsDirectoryIndex? = nil,
        includeSearchMetadata: Bool = true
    ) async -> Note {
        let nameCreated = FileStore.recordingDateFromFileName(file)
        let fileCreated = nameCreated ?? ((try? FileStore.fileCreationDate(file)) ?? Date())
        let fileModified = FileStore.fileModificationDate(file)
        let isAudio = FileStore.isAudioFile(file)

        // One read. Search text is the sidecar's own UTF-8, not a sorted re-encode.
        let built = await metaRepo.metadataForBuild(for: file, includeSearchText: includeSearchMetadata)
        let docMeta = built.dictionary
        let noteCard = built.noteCard
        let transcriptionDict = docMeta["transcription"] as? [String: Any]
        let speechStatus = (transcriptionDict?["speechStatus"] as? String)
            .flatMap(TranscriptionSpeechStatus.init(rawValue:))

        // ── Body: the shared resolver; a text note's body is its file ──
        let content = NoteContent.load(anchor: file, sidecar: docMeta)
        let isTypedFile = content.isTypedFile
        let transcript: String?
        if isTypedFile {
            transcript = content.body
        } else if content.bodySource == .transcript || content.bodySource == .legacyTranscript {
            transcript = content.body
        } else {
            transcript = await transcriptRepo.transcriptText(for: file)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Missing raw is a valid state, not a reason to read the sidecar
        // again. Infer provider/model from the dictionary already in hand.
        let info: MetadataRepository.TranscriptionInfo
        if let transcriptionDict {
            info = MetadataRepository.transcriptionInfo(from: transcriptionDict)
        } else if isTypedFile {
            info = .init(provider: nil, model: nil, hasRaw: false)
        } else {
            // Old notes may keep this only in the legacy _mini sidecar.
            info = await metaRepo.transcriptionInfo(for: file)
        }
        let tProvider = info.provider
        let tModel = info.model
        let hasRaw = info.hasRaw

        // ── Assets: direct path computation (no fileExists) ──
        let screenshotURL = fastScreenshotURL(for: file, directoryIndex: directoryIndex)
        let metadataURL = FileStore.metadataURL(forRecordingURL: file)
        let metadataSearchText = built.searchText

        // ── Document metadata ──
        let docInfo = docMeta["document"] as? [String: Any]
        let pageCount = docInfo.flatMap { doc -> Int? in
            (doc["pageCount"] as? Int) ?? (doc["pageCount"] as? NSNumber)?.intValue
        }
        let docTextProvider = docInfo?["textProvider"] as? String
        let docTextModel = docInfo?["textModel"] as? String

        // ── OCR ──
        let ocrMeta = docMeta["ocr"] as? [String: Any]
        let ocrProvider = ocrMeta?["provider"] as? String
        let ocrModel = ocrMeta?["model"] as? String
        let ocrText = ocrMeta?["text"] as? String

        // ── Attachments: inline parse from dict (no actor hop) ──
        var attachments = parseAttachments(from: docMeta)
        // LEGACY: Virtual attachment for old OCR format
        if attachments.isEmpty, let ocrText = ocrText, !ocrText.isEmpty,
           let screenshot = screenshotURL {
            attachments.append(NoteAttachment(
                id: UUID(), url: screenshot, type: "image",
                extractedText: ocrText, extractionProvider: ocrProvider,
                extractionModel: ocrModel))
        }

        // ── NoteCard fields ──
        let title = noteCard?.title ?? docInfo?["title"] as? String
        let summary = noteCard?.summary
        let refinedText = noteCard?.refined_text
        let isArtifact = noteCard?.is_artifact ?? false
        let isLiked = noteCard?.is_liked ?? false
        let isInsight = noteCard?.is_insight ?? false
        let connectedNoteIds = noteCard?.connected_note_ids
        let agentRecommendation = noteCard?.agent_recommendation
            ?? transcriptionDict?["agentRecommendation"] as? String
        let agentReason = noteCard?.agent_reason
            ?? transcriptionDict?["agentReason"] as? String
        let isCanceled = docMeta["isCanceled"] as? Bool ?? false
        let processedAt = noteCard?.processed_at
        let isImported = docMeta["sourcePath"] != nil || docMeta["importSource"] != nil

        // ── Compute text & isFailed ──
        let stableId = file.stableUUID
        let text: String
        let isFailed: Bool
        let noteEnd: Double
        // Recordings the silence gate skipped before transcription carry no
        // transcription dict at all; their duration lives in streamingSkipDurationSec.
        let isStreamingSkipped = (docMeta["isStreamingSkipped"] as? Bool) ?? false
        let skippedWithoutTranscript = isStreamingSkipped && transcript == nil
        // A gate skip is the same verdict as the model's [[NO_SPEECH]], reached
        // before upload: report it as such, or the stage classifier reads the
        // "No speech detected" placeholder below as a real transcript.
        let effectiveSpeechStatus: TranscriptionSpeechStatus? =
            isAudio && skippedWithoutTranscript ? .noSpeech : speechStatus
        if isAudio {
            if speechStatus == .noSpeech || skippedWithoutTranscript {
                text = "No speech detected"
                isFailed = false
                noteEnd = (transcriptionDict?["audioDurationSec"] as? Double)
                    ?? (docMeta["streamingSkipDurationSec"] as? Double) ?? 0
            } else {
                let fullText = (transcript?.isEmpty == false) ? transcript! : "Transcription failed"
                let lower = fullText.lowercased()
                text = fullText
                isFailed = transcript == nil || lower == "transcription failed"
                    || lower == "no text recognized"
                noteEnd = (transcriptionDict?["audioDurationSec"] as? Double)
                    ?? (docMeta["streamingSkipDurationSec"] as? Double) ?? 0
            }
        } else if isTypedFile {
            // Unreadable is not empty: say so instead of showing nothing.
            text = transcript ?? (content.fileUnreadable ? NoteContent.unreadableFilePlaceholder : "")
            isFailed = false
            noteEnd = 0
        } else if let transcript, !transcript.isEmpty {
            text = transcript
            isFailed = false
            noteEnd = 0
        } else if let docText = (docInfo?["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !docText.isEmpty {
            // Older document imports stored extracted text only under
            // document.text without a transcript; don't render them as failed.
            text = docText
            isFailed = false
            noteEnd = 0
        } else {
            text = "No text recognized"
            isFailed = true
            noteEnd = 0
        }

        return Note(
            id: stableId,
            index: index,
            fileURL: file,
            fileCreated: fileCreated,
            start: 0,
            end: noteEnd,
            text: text,
            refinedText: refinedText,
            isFailed: isFailed,
            isImported: isImported,
            screenshotURL: screenshotURL,
            metadataURL: metadataURL,
            metadataSearchText: metadataSearchText,
            documentPageCount: pageCount,
            origin: NoteOrigin.displayString(metadata: docMeta, fileName: file.lastPathComponent),
            transcriptionProvider: tProvider,
            transcriptionModel: tModel,
            transcriptionSpeechStatus: effectiveSpeechStatus,
            detectedAudioSpeechLabel: isAudio ? AudioSpeechClassification.detected(in: docMeta, speechStatus: effectiveSpeechStatus) : nil,
            audioSpeechLabelOverride: isAudio ? AudioSpeechClassification.override(in: docMeta) : nil,
            hasRaw: hasRaw,
            projectId: nil,
            projectName: nil,
            projectConfidence: nil,
            projectWhy: nil,
            extractionProvider: docTextProvider ?? ocrProvider,
            extractionModel: docTextModel ?? ocrModel,
            attachments: attachments,
            title: title,
            summary: summary,
            agentRecommendation: agentRecommendation,
            agentReason: agentReason,
            fileModified: fileModified,
            isArtifact: isArtifact,
            isLiked: isLiked,
            isInsight: isInsight,
            suspectedNoSpeech: (docMeta["suspectedNoSpeech"] as? Bool) ?? false
                || skippedWithoutTranscript,
            processedAt: processedAt,
            isUnprocessed: false,
            isCanceled: isCanceled,
            connectedNoteIds: connectedNoteIds
        )
    }

    // MARK: - Helpers

    /// Produces a compact, deterministic representation of the complete sidecar.
    /// Callers that already hold the file bytes should use `searchableMetadataText(bytes:parsed:)`
    /// so journal construction does not encode the dictionary again.
    public static func searchableMetadataText(from metadata: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(
                  withJSONObject: metadata,
                  options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text
    }

    /// Search text for a sidecar already read from disk. The file's UTF-8 is
    /// kept as written: keys, values and numbers stay searchable without a
    /// second encode. A `\u` escape is decoded by falling back to the parsed
    /// object, because the raw escape would not match the character itself.
    /// `Note` folds case once when it stores the result.
    public static func searchableMetadataText(bytes: Data, parsed: [String: Any]) -> String {
        if !containsUnicodeEscape(bytes), let text = String(data: bytes, encoding: .utf8) {
            return text
        }
        return searchableMetadataText(from: parsed)
    }

    /// JSON `\uXXXX` is the only escape that hides a searchable character.
    /// Quotes and newlines stay escaped in both the file and a re-encoded object.
    static func containsUnicodeEscape(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            guard bytes.count >= 2 else { return false }
            for offset in 0..<(bytes.count - 1) where bytes[offset] == 0x5C && bytes[offset + 1] == 0x75 {
                return true
            }
            return false
        }
    }

    /// Parse attachments from metadata dict (no actor hop).
    public static func parseAttachments(from meta: [String: Any]) -> [NoteAttachment] {
        guard let list = meta["attachments"] as? [[String: Any]] else { return [] }
        return list.compactMap { dict -> NoteAttachment? in
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr),
                  let type = dict["type"] as? String else { return nil }
            return NoteAttachment(
                id: id, url: url, type: type,
                extractedText: dict["extractedText"] as? String ?? dict["ocrText"] as? String,
                extractionProvider: dict["extractionProvider"] as? String ?? dict["ocrProvider"] as? String,
                extractionModel: dict["extractionModel"] as? String ?? dict["ocrModel"] as? String
            )
        }
    }

    /// Compute the primary screenshot URL for legacy, multi-screen, and attachment-backed captures.
    /// When a `RecordingsDirectoryIndex` covering the file's directory is supplied,
    /// resolution is pure set lookups; otherwise it falls back to filesystem checks.
    public static func fastScreenshotURL(
        for file: URL,
        directoryIndex: RecordingsDirectoryIndex? = nil
    ) -> URL? {
        let preview: URL?
        if let directoryIndex, directoryIndex.covers(directoryOf: file) {
            preview = directoryIndex.firstScreenshotURL(forRecordingURL: file)
        } else {
            preview = FileStore.allScreenshotURLs(forRecordingURL: file).first
        }
        // An imported .jpg/.png note is its own picture: no `{base}.heic` exists.
        if preview == nil, AttachmentTypeHelper.imageExtensions.contains(file.pathExtension.lowercased()) {
            return file
        }
        return preview
    }
}
