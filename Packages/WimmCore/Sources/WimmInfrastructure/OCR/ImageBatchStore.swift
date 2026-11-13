import Foundation
import WimmDomain

/// Commit only derived image data, merging current sidecars. No note bodies/audio,
/// analysis cards, marks, boundaries or glossary entries are modified here.
public enum ImageBatchStore {
    public static func apply(_ records: [(LibraryImageInventory.Target, ImageBatchRecord)], to note: URL) throws -> Int {
        var changed = 0
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) { meta in
            var screenshots = (meta["ocr"] as? [String: Any])?["images"] as? [[String: Any]] ?? []
            var rootRecord: ImageBatchRecord?
            let previousOCR = (meta["ocr"] as? [String:Any])?["text"] as? String ?? ""
            let previousDocument = (meta["document"] as? [String:Any])?["text"] as? String ?? ""
            let oldSource = (meta["ocr"] as? [String:Any])?["source"] as? String
            let stem = note.deletingPathExtension()
            let audioEvidence = oldSource == "screenshot" || oldSource == "screenshots" ||
                FileManager.default.fileExists(atPath:FileStore.microURL(forRecordingURL:note).path) ||
                FileManager.default.fileExists(atPath:FileStore.miniURL(forRecordingURL:note).path) ||
                FileStore.supportedAudioExtensions.contains { FileManager.default.fileExists(atPath:stem.appendingPathExtension($0).path) }
            for (target, record) in records where record.isComplete {
                var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
                json["source"] = FileStore.relativePath(for: URL(fileURLWithPath: record.source))
                json["text"] = record.text
                let text = record.text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch target.kind {
                case .orphan: continue
                case .attachment:
                    var attachments = meta["attachments"] as? [[String: Any]] ?? []
                    let index = attachments.firstIndex { item in
                        if let raw = item["url"] as? String, let url = NoteAttachmentMedia.resolve(raw) {
                            return url.standardizedFileURL.resolvingSymlinksInPath().path == target.image
                        }
                        return (item["id"] as? String).flatMap(UUID.init(uuidString:)) == target.attachmentID
                    }
                    let i: Int
                    if let index { i = index } else {
                        guard let id = target.attachmentID,
                              FileStore.isAttachmentFile(URL(fileURLWithPath: target.image)),
                              FileStore.metadataURL(forRecordingURL: URL(fileURLWithPath: target.image)) == FileStore.metadataURL(forRecordingURL: note) else {
                            throw NSError(domain: "ImageBatchStore", code: 2, userInfo: [NSLocalizedDescriptionKey:"Attachment was removed or has no verified legacy parent"])
                        }
                        // Legacy filename-backed attachments are already library assets.
                        // Register their durable URL without creating a new note.
                        attachments.append(["id": id.uuidString, "url": URL(fileURLWithPath: target.image).absoluteString, "type": "image"])
                        i = attachments.count - 1
                    }
                    let old = (attachments[i]["extractedText"] as? String ?? attachments[i]["ocrText"] as? String ?? "")
                    if !text.isEmpty || old.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        archivePreviousExtractionRun(in: &attachments[i], replacingWith: text, textKey: "extractedText",
                            legacyTextKey: "ocrText", providerKey: "extractionProvider", legacyProviderKey: "ocrProvider",
                            modelKey: "extractionModel", legacyModelKey: "ocrModel")
                        attachments[i]["extractedText"] = text
                        attachments[i]["extractionProvider"] = record.provider
                        attachments[i]["extractionModel"] = record.model
                    }
                    attachments[i]["startedAt"] = record.completedAt ?? ISO8601.string(from: Date())
                    try ImageAnalysisHistory.store(record,in:&attachments[i])
                    meta["attachments"] = attachments
                    changed += 1
                case .standalone:
                    guard LibraryImageInventory.isImage(note), !FileStore.isAttachmentFile(note) else {
                        throw NSError(domain: "ImageBatchStore", code: 1, userInfo: [NSLocalizedDescriptionKey:"Refusing to replace a non-image or parent transcript"])
                    }
                    rootRecord = record; changed += 1
                case .screenshot:
                    let i = screenshots.firstIndex { value in
                        guard let raw = value["source"] as? String, let url = NoteAttachmentMedia.resolve(raw) else { return false }
                        return url.standardizedFileURL.resolvingSymlinksInPath().path == target.image
                    }
                    if let i {
                        let oldText = (screenshots[i]["text"] as? String) ?? ""
                        if text.isEmpty && !oldText.isEmpty { screenshots[i]["lastEmptyAttempt"] = json }
                        else {
                            var container = screenshots[i]
                            // Screenshot rows are records themselves, so retain earlier full rows.
                            var history = container["previousImageAnalyses"] as? [[String:Any]] ?? []
                            container.removeValue(forKey:"previousImageAnalyses")
                            if !NSDictionary(dictionary:container).isEqual(to:json) { history.append(container) }
                            json["previousImageAnalyses"] = history
                            screenshots[i] = json
                        }
                    } else { screenshots.append(json) }
                    changed += 1
                }
            }
            if let record = rootRecord {
                var ocr = meta["ocr"] as? [String: Any] ?? [:]
                let old = ocr["text"] as? String ?? ""
                if !record.text.isEmpty || old.isEmpty {
                    archivePreviousExtractionRun(in: &ocr, replacingWith: record.text)
                    ocr["text"] = record.text; ocr["provider"] = record.provider; ocr["model"] = record.model
                    ocr["source"] = oldSource ?? "image"
                    ocr["startedAt"] = record.completedAt ?? ISO8601.string(from: Date())
                    ocr["elapsedMs"] = Int(record.seconds * 1000)
                }
                try ImageAnalysisHistory.store(record,in:&ocr)
                meta["ocr"] = ocr
                if !record.text.isEmpty {
                    var doc = meta["document"] as? [String: Any] ?? [:]
                    archivePreviousExtractionRun(in: &doc, replacingWith: record.text, providerKey: "textProvider", modelKey: "textModel")
                    doc["text"] = record.text; doc["textProvider"] = record.provider; doc["textModel"] = record.model
                    meta["document"] = doc
                    // A screenshot can become the anchor after its original audio was
                    // lost. Never mistake that for permission to replace the voice text.
                    var transcription = FileStore.transcriptionDictionary(from: meta["transcription"]) ?? [:]
                    let prior = transcription["transcript"] as? String ?? ""
                    let knownImageOCR = !audioEvidence && (prior.isEmpty || prior == previousOCR || prior == previousDocument)
                    if knownImageOCR {
                        archivePreviousRun(in: &transcription, replacingWith: record.text)
                        for key in transcriptionRunScopedKeys.union(transcriptionContentKeys).union(transcriptionDerivedKeys) { transcription.removeValue(forKey:key) }
                        transcription["transcript"] = record.text; transcription["provider"] = record.provider
                        transcription["model"] = record.model; transcription["speechStatus"] = "speech"
                        transcription["startedAt"] = record.completedAt ?? ISO8601.string(from:Date())
                        meta["transcription"] = transcription
                    }
                }
            }
            if !screenshots.isEmpty {
                var ocr = meta["ocr"] as? [String: Any] ?? [:]
                let combined = screenshots.compactMap { value -> String? in
                    guard let raw = try? JSONSerialization.data(withJSONObject: value),
                          let record = try? JSONDecoder().decode(ImageBatchRecord.self, from: raw), !record.text.isEmpty else { return nil }
                    return "[image source: \(URL(fileURLWithPath: record.source).lastPathComponent)]\n" + record.text
                }.joined(separator: "\n\n")
                let old = ocr["text"] as? String ?? ""
                if !combined.isEmpty || old.isEmpty {
                    archivePreviousExtractionRun(in: &ocr, replacingWith: combined)
                    ocr["text"] = combined; ocr["provider"] = screenshots.contains { $0["caption"] != nil } ? "on-device" : "vision"
                    ocr["model"] = "Vision image batch"
                    ocr["startedAt"] = ISO8601.string(from: Date())
                    ocr["source"] = "screenshots"
                }
                ocr["images"] = screenshots; meta["ocr"] = ocr
            }
            return changed > 0
        }
        return changed
    }
}
