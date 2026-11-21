import Foundation
import WimmDomain

/// Writes a note's own OCR result. One note = one media: every image or
/// document is its own note, so the text goes into its own sidecar (`ocr`, and
/// `document` for a non-audio note), never into another note's `attachments`.
public enum NoteOCRStore {
    /// OCR of a standalone document also becomes the transcript run the Reader
    /// uses as its body. A recording's screenshot keeps the recording's body.
    public static func saveDocumentOCR(for file: URL, text: String, provider: String, model: String,
                                       startedAt: Date, metadataRepository: MetadataRepository = MetadataRepository()) async {
        await saveOCR(for: file, text: text, provider: provider, model: model, startedAt: startedAt,
                      metadataRepository: metadataRepository)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !FileStore.isAudioFile(file), !FileStore.isAttachmentFile(file) else { return }
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        recordRunSuccess(
            file: file, provider: provider, model: model,
            audioDuration: max(10, min(3600, Double(words) / 180 * 60)),
            startedAt: startedAt, elapsedSeconds: Date().timeIntervalSince(startedAt),
            transcript: trimmed, speechStatus: .speech, rawResponse: nil
        )
    }

    public static func saveOCR(for file: URL, text: String, provider: String, model: String, startedAt: Date,
                               metadataRepository: MetadataRepository = MetadataRepository()) async {
        let iso = ISO8601.string(from: startedAt)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = await metadataRepository.metadata(for: file)
        var ocrDict = meta["ocr"] as? [String: Any] ?? [:]
        let existingOCR = (ocrDict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedText.isEmpty || existingOCR.isEmpty else { return }

        archivePreviousExtractionRun(in: &ocrDict, replacingWith: text, textKey: "text",
                                     providerKey: "provider", modelKey: "model")
        ocrDict["provider"] = provider
        ocrDict["model"] = model
        ocrDict["startedAt"] = iso
        ocrDict["elapsedMs"] = elapsedMs
        ocrDict["source"] = FileStore.isAudioFile(file) ? "screenshot" : "image"
        ocrDict["text"] = text
        await metadataRepository.upsertMetadata(for: file, updates: ["ocr": ocrDict])

        guard !FileStore.isAudioFile(file), !trimmedText.isEmpty else { return }
        var doc = meta["document"] as? [String: Any] ?? [:]
        archivePreviousExtractionRun(in: &doc, replacingWith: trimmedText, textKey: "text",
                                     providerKey: "textProvider", modelKey: "textModel")
        doc["text"] = trimmedText
        doc["startedAt"] = iso
        let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProvider.isEmpty { doc["textProvider"] = trimmedProvider }
        if !trimmedModel.isEmpty { doc["textModel"] = trimmedModel }
        await metadataRepository.upsertMetadata(for: file, updates: ["document": doc])
    }
}
