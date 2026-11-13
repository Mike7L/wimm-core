import Foundation
import WimmDomain

/// Handles attachment management and OCR saving.
/// Delegates persistence to MetadataRepository to ensure thread safety on manifest.json.
public actor AttachmentRepository: AttachmentRepositoryProtocol {
    
    private let fileManager = FileManager.default
    private let metadataRepository: any MetadataRepositoryProtocol
    
    public init(metadataRepository: any MetadataRepositoryProtocol) {
        self.metadataRepository = metadataRepository
    }

    // MARK: - Attachments

    public func attachments(for file: URL) async -> [NoteAttachment] {
        await attachments(for: file, migrateLegacyKeys: true)
    }

    /// Inspection paths can decode legacy keys without rewriting the sidecar.
    public func attachments(for file: URL, migrateLegacyKeys: Bool) async -> [NoteAttachment] {
        let meta = await metadataRepository.metadata(for: file)
        guard let list = meta["attachments"] as? [[String: Any]] else { return [] }
        var decoded: [NoteAttachment] = []
        var legacyFieldsDetected = false

        for dict in list {
            guard let idStr = dict["id"] as? String,
                  let id = UUID(uuidString: idStr),
                  let urlStr = dict["url"] as? String,
                  let url = URL(string: urlStr),
                  let type = dict["type"] as? String else { continue }

            let extractedText = dict["extractedText"] as? String ?? dict["ocrText"] as? String
            let extractionProvider = dict["extractionProvider"] as? String ?? dict["ocrProvider"] as? String
            let extractionModel = dict["extractionModel"] as? String ?? dict["ocrModel"] as? String

            if dict["ocrText"] != nil || dict["ocrProvider"] != nil || dict["ocrModel"] != nil {
                legacyFieldsDetected = true
            }

            decoded.append(NoteAttachment(
                id: id,
                url: url,
                type: type,
                extractedText: extractedText,
                extractionProvider: extractionProvider,
                extractionModel: extractionModel
            ))
        }

        // Opportunistic migration: rewrite legacy attachment keys to extracted*.
        if legacyFieldsDetected && migrateLegacyKeys {
            await upsertAttachments(for: file, attachments: decoded)
        }

        return decoded
    }
    
    public func upsertAttachments(for file: URL, attachments: [NoteAttachment]) async {
        let meta = await metadataRepository.metadata(for: file)
        let existingList = meta["attachments"] as? [[String: Any]] ?? []
        let jsonCompatible = attachments.map { attachment -> [String: Any] in
            let idString = attachment.id.uuidString
            let urlString = attachment.url.absoluteString
            var dict = existingList.first(where: {
                ($0["id"] as? String) == idString || ($0["url"] as? String) == urlString
            }) ?? [:]

            if let extracted = attachment.extractedText {
                archivePreviousExtractionRun(
                    in: &dict,
                    replacingWith: extracted,
                    textKey: "extractedText",
                    legacyTextKey: "ocrText",
                    providerKey: "extractionProvider",
                    legacyProviderKey: "ocrProvider",
                    modelKey: "extractionModel",
                    legacyModelKey: "ocrModel",
                    ignoreValue: NoteAttachmentMedia.noSpeechText
                )
                dict["extractedText"] = extracted
            }
            dict["id"] = idString
            dict["url"] = urlString
            dict["type"] = attachment.type
            if let provider = attachment.extractionProvider { dict["extractionProvider"] = provider }
            if let model = attachment.extractionModel { dict["extractionModel"] = model }
            for legacy in ["ocrText", "ocrProvider", "ocrModel"] { dict.removeValue(forKey: legacy) }
            return dict
        }
        await metadataRepository.upsertMetadata(for: file, updates: ["attachments": jsonCompatible])
    }

    // MARK: - OCR

    /// OCR of a standalone document must also replace the transcript the Reader
    /// uses as its body. Screenshots and attachments keep their parent's body.
    public func saveDocumentOCR(for file: URL, text: String, provider: String, model: String, startedAt: Date) async {
        await saveOCR(for: file, text: text, provider: provider, model: model, startedAt: startedAt)
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
    
    /// Unified method to save OCR results for any file (main or attachment)
    /// Automatically determines whether to save to root metadata or attachments array
    public func saveOCR(for file: URL, text: String, provider: String, model: String, startedAt: Date) async {
        let iso = ISO8601.string(from: startedAt)
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if this is an attachment file
        if FileStore.isAttachmentFile(file) {
            // For attachments, update the attachments array
            guard let parentFile = findParentSessionFile(for: file) else {
                log("Could not find parent session for attachment: \(file.lastPathComponent)")
                return
            }
            
            var attachments = await attachments(for: parentFile)
            
            if let index = attachments.firstIndex(where: { $0.url == file }) {
                // Update existing attachment
                let existing = attachments[index]
                attachments[index] = NoteAttachment(
                    id: existing.id,
                    url: file,
                    type: existing.type,
                    extractedText: text,
                    extractionProvider: provider,
                    extractionModel: model
                )
            } else {
                // Create new attachment entry
                let type = ["png", "jpg", "jpeg", "heic"].contains(file.pathExtension.lowercased()) ? "image" : "file"
                attachments.append(NoteAttachment(
                    id: UUID(),
                    url: file,
                    type: type,
                    extractedText: text,
                    extractionProvider: provider,
                    extractionModel: model
                ))
            }
            
            await upsertAttachments(for: parentFile, attachments: attachments)
        } else {
            let meta = await metadataRepository.metadata(for: file)
            var ocrDict = meta["ocr"] as? [String: Any] ?? [:]
            let existingOCR = (ocrDict["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedText.isEmpty || existingOCR.isEmpty else { return }

            archivePreviousExtractionRun(
                in: &ocrDict,
                replacingWith: text,
                textKey: "text",
                providerKey: "provider",
                modelKey: "model"
            )
            ocrDict["provider"] = provider
            ocrDict["model"] = model
            ocrDict["startedAt"] = iso
            ocrDict["elapsedMs"] = elapsedMs
            ocrDict["source"] = FileStore.isAudioFile(file) ? "screenshot" : "image"
            ocrDict["text"] = text
            await metadataRepository.upsertMetadata(for: file, updates: ["ocr": ocrDict])

            if !FileStore.isAudioFile(file), !trimmedText.isEmpty {
                var doc = meta["document"] as? [String: Any] ?? [:]
                archivePreviousExtractionRun(
                    in: &doc,
                    replacingWith: trimmedText,
                    textKey: "text",
                    providerKey: "textProvider",
                    modelKey: "textModel"
                )
                doc["text"] = trimmedText
                doc["startedAt"] = iso
                let trimmedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedProvider.isEmpty { doc["textProvider"] = trimmedProvider }
                if !trimmedModel.isEmpty { doc["textModel"] = trimmedModel }
                await metadataRepository.upsertMetadata(for: file, updates: ["document": doc])
            }
        }
    }
    
    public func findParentSessionFile(for attachmentFile: URL) -> URL? {
        guard let sessionID = FileStore.parentSessionID(forAttachment: attachmentFile) else { return nil }
        
        let dir = attachmentFile.deletingLastPathComponent()
        
        // Look for primary m4a file
        let m4aURL = dir.appendingPathComponent("\(sessionID).m4a")
        if fileManager.fileExists(atPath: m4aURL.path) {
            return m4aURL
        }
        
        // Fallback: look for any file with this session ID
        guard let files = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.deletingPathExtension().lastPathComponent == sessionID }
    }
}
