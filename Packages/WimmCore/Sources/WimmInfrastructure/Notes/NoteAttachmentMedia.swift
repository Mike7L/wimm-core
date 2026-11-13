import Foundation
import WimmDomain

/// The media a note carries as attachments, read from its sidecar, and the one
/// write that sets an attachment's extracted text.
///
/// Evernote imports are `.txt` notes whose audio, photos and PDFs live under
/// `Attachments/Evernote/<note id>/` and are listed only in the note's
/// `attachments` array. The note itself is "text", so anything that works on a
/// note's own audio file (retranscription, OCR) has to look here to reach them.
public enum NoteAttachmentMedia {
    /// The model's "nothing said" verdict as stored on an attachment
    /// (`TranscriptionSupport.noSpeechSentinel`, which lives in WimmTranscription).
    public static let noSpeechText = "[[NO_SPEECH]]"

    public struct Item: Sendable, Equatable {
        public let id: UUID
        public let url: URL
        public let type: String
        /// Trimmed extracted text (transcript, OCR, PDF text); nil when blank.
        public let text: String?
        public let provider: String?
        public let model: String?
        /// Earlier extracted texts/OCR runs a new run replaced (`previousRuns`), newest first.
        public let previousRuns: [TranscriptRun]
        /// A text extraction ran, even one that found nothing (OCR of a photo
        /// without writing stores an empty text with its provider).
        public let wasExtracted: Bool

        public var isAudio: Bool { FileStore.isAudioFile(url) && !FileStore.isDerivedAudioFile(url) }
        public var isImage: Bool { NoteAttachmentMedia.imageExtensions.contains(url.pathExtension.lowercased()) }
        public var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
        public var isNoSpeech: Bool { text == NoteAttachmentMedia.noSpeechText }
        /// Text a reader would call content: not blank, not the no-speech verdict.
        public var hasMeaningfulText: Bool { text != nil && !isNoSpeech }
    }

    /// Image types Vision can read. SVG is drawn, not photographed — skipped.
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]

    public static func items(ofNote noteURL: URL) -> [Item] {
        let sidecar = FileStore.metadataURL(forRecordingURL: noteURL)
        guard let data = try? Data(contentsOf: sidecar),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return items(in: root)
    }

    public static func items(in sidecar: [String: Any]) -> [Item] {
        (sidecar["attachments"] as? [[String: Any]] ?? []).compactMap { dict in
            guard let rawID = dict["id"] as? String, let id = UUID(uuidString: rawID),
                  let rawURL = dict["url"] as? String, let url = resolve(rawURL)
            else { return nil }
            let text = (dict["extractedText"] as? String ?? dict["ocrText"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let allRuns = TranscriptRuns.extractionRuns(
                in: dict,
                textKey: "extractedText",
                legacyTextKey: "ocrText",
                providerKey: "extractionProvider",
                legacyProviderKey: "ocrProvider",
                modelKey: "extractionModel",
                legacyModelKey: "ocrModel",
                ignoreValue: noSpeechText
            )
            return Item(
                id: id,
                url: url,
                type: dict["type"] as? String ?? "file",
                text: text?.isEmpty == false ? text : nil,
                provider: dict["extractionProvider"] as? String ?? dict["ocrProvider"] as? String,
                model: dict["extractionModel"] as? String ?? dict["ocrModel"] as? String,
                previousRuns: allRuns.filter { !$0.isCurrent },
                wasExtracted: text?.isEmpty == false
                    || (dict["extractedText"] != nil && dict["extractionProvider"] != nil)
            )
        }
    }

    /// Audio attachments whose file is on disk.
    public static func audio(ofNote noteURL: URL) -> [Item] {
        items(ofNote: noteURL).filter { $0.isAudio && FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Attachment URLs are stored as `file://` URLs, absolute paths, or paths
    /// relative to the library (Evernote's `Attachments/Evernote/…`).
    public static func resolve(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.isFileURL { return url.standardizedFileURL }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardizedFileURL }
        guard !raw.isEmpty, !raw.contains("://") else { return nil }
        return FileStore.resolveRelativePath(raw).standardizedFileURL
    }

    public enum WriteResult: Equatable, Sendable {
        case written
        /// A no-speech verdict met existing text, which stays (the same rule
        /// `recordRunSuccess` keeps for a note's own transcript).
        case keptExisting
        case attachmentMissing
    }

    /// Sets one attachment's extracted text inside the parent's sidecar, in
    /// place: the rest of the entry (and of the sidecar) is left as it is.
    /// For audio (`emptyIsNoSpeech`) an empty text is the no-speech verdict;
    /// for OCR it is stored empty, so a photo without writing is not read again.
    @discardableResult
    public static func setText(
        _ text: String,
        provider: String,
        model: String?,
        attachmentID: UUID,
        ofNote noteURL: URL,
        emptyIsNoSpeech: Bool = true
    ) throws -> WriteResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = WriteResult.attachmentMissing
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: noteURL)) { meta in
            var list = meta["attachments"] as? [[String: Any]] ?? []
            guard let i = list.firstIndex(where: { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == attachmentID })
            else { return false }
            let existing = (list[i]["extractedText"] as? String ?? list[i]["ocrText"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed == noSpeechText || trimmed.isEmpty, !existing.isEmpty, existing != noSpeechText {
                result = .keptExisting
                return false
            }
            let newStoredText = trimmed.isEmpty && emptyIsNoSpeech ? noSpeechText : trimmed
            archivePreviousExtractionRun(
                in: &list[i],
                replacingWith: newStoredText,
                textKey: "extractedText",
                legacyTextKey: "ocrText",
                providerKey: "extractionProvider",
                legacyProviderKey: "ocrProvider",
                modelKey: "extractionModel",
                legacyModelKey: "ocrModel",
                ignoreValue: noSpeechText
            )
            list[i]["extractedText"] = newStoredText
            list[i]["extractionProvider"] = provider
            list[i]["startedAt"] = ISO8601.string(from: Date())
            if let model { list[i]["extractionModel"] = model } else { list[i].removeValue(forKey: "extractionModel") }
            for legacy in ["ocrText", "ocrProvider", "ocrModel"] { list[i].removeValue(forKey: legacy) }
            meta["attachments"] = list
            result = .written
            return true
        }
        return result
    }
}
