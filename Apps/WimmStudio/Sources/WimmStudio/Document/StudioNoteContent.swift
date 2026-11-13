import Foundation
import WimmDomain
import WimmInfrastructure

/// Only the opened note retains its full texts. The timeline stays a compact projection.
struct StudioNoteContent: Sendable {
    struct Tab: Identifiable, Sendable {
        enum Content: Sendable {
            case body
            case text(String, detail: String)
            case source(URL)
            case history
        }
        let id: String
        let title: String
        let content: Content
    }

    var note: Note
    var tabs: [Tab]
    var versions: [NoteVersion]
    let initialTabID: String
    let audioURL: URL?
    /// Used to reject a save over a body another editor has replaced.
    var expectedRefinedText: String?

    init(note: Note, metadata: [String: Any], versions: [NoteVersion]) {
        self.note = note
        self.versions = versions
        expectedRefinedText = note.refinedText
        audioURL = FileStore.isAudioFile(note.fileURL) ? note.fileURL : nil
        var tabs: [Tab] = [.init(id: "body", title: "Текст заметки", content: .body)]
        var seenURLs: Set<URL> = []
        func appendSource(_ url: URL, title: String) {
            guard seenURLs.insert(url.standardizedFileURL).inserted else { return }
            tabs.append(.init(id: "source:\(url.path)", title: title, content: .source(url)))
        }
        func alreadyHasText(_ text: String) -> Bool {
            tabs.contains { tab in
                if case .text(let existing, _) = tab.content { return existing == text }
                return false
            }
        }
        let primaryType = AttachmentTypeHelper.determineType(for: note.fileURL)
        let isImage = NoteAttachmentMedia.imageExtensions.contains(note.fileURL.pathExtension.lowercased())
        let isVisual = audioURL == nil && (isImage || primaryType == .pdf || primaryType == .document)
        if isVisual {
            appendSource(note.fileURL, title: isImage ? "Картинка" : "Документ")
        }
        if let screenshot = note.screenshotURL { appendSource(screenshot, title: "Снимок экрана") }

        // Read the actual extraction, rather than substituting an analysis or guessing that
        // every image with OCR is a scan. Image and PDF originals share the source viewer.
        for (key, title) in [("document", "Текст документа"), ("ocr", "Распознанный текст")] {
            if let dictionary = metadata[key] as? [String: Any],
               let text = dictionary["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tabs.append(.init(id: key, title: title, content: .text(text, detail: "Сохранённый текст источника")))
            }
        }
        for variant in NoteTranscriptVariant.variants(fromSidecar: metadata) {
            let rendered = variant.rendered { "Говорящий \($0)" }
            // Legacy OCR can appear under extraction, transcription and a synthetic
            // attachment simultaneously. Keep every distinct text without redundant buttons.
            if audioURL == nil, alreadyHasText(rendered.text) { continue }
            let title: String
            switch variant.kind {
            case .realtime: title = "Во время записи"
            case .local: title = audioURL != nil ? "Локальная" : "Локальный текст"
            case .cloud: title = audioURL != nil ? "Облачная" : "Облачный текст"
            case .current: title = audioURL != nil ? "Расшифровка" : "Извлечённый текст"
            case .speakers: title = "По говорящим"
            case .previous: title = "Ранее · \(variant.date?.formatted(date: .abbreviated, time: .shortened) ?? variant.model ?? "расшифровка")"
            }
            let detail = [variant.provider, variant.model,
                          variant.date?.formatted(date: .abbreviated, time: .shortened)]
                .compactMap { $0 }.joined(separator: " · ")
            tabs.append(.init(id: "transcript:\(variant.id)", title: title,
                              content: .text(rendered.text, detail: detail)))
        }
        for (index, attachment) in note.attachments.enumerated() {
            let title = "\(index + 1) · \(attachment.url.lastPathComponent)"
            let wasKnownSource = seenURLs.contains(attachment.url.standardizedFileURL)
            appendSource(attachment.url, title: title)
            if let text = attachment.extractedText, !text.isEmpty, text != NoteAttachmentMedia.noSpeechText {
                if wasKnownSource, alreadyHasText(text) { continue }
                tabs.append(.init(id: "attachment-text:\(attachment.id)", title: "Текст · \(title)",
                                  content: .text(text, detail: attachment.extractionModel ?? "Текст вложения")))
            }
        }
        // Earlier attachment extractions are evidence too; never drop them from the reader.
        for item in NoteAttachmentMedia.items(in: metadata) {
            for (index, run) in item.previousRuns.enumerated() {
                tabs.append(.init(id: "attachment-history:\(item.id):\(index)",
                                  title: "Ранее · \(item.url.lastPathComponent) · \(index + 1)",
                                  content: .text(run.text, detail: run.model ?? "Прежний текст вложения")))
            }
        }
        if isVisual, let index = tabs.firstIndex(where: { $0.id == "source:\(note.fileURL.path)" }) {
            let original = tabs.remove(at: index)
            let body = tabs.removeFirst()
            tabs.insert(original, at: 0)
            tabs.append(body)
        }
        if !versions.isEmpty { tabs.append(.init(id: "history", title: "История", content: .history)) }
        self.tabs = tabs
        initialTabID = isVisual ? "source:\(note.fileURL.path)" : "body"
    }

    var bodyText: String { note.refinedText ?? note.text }

    static func load(file: URL, history: NoteVersionStore) async -> StudioNoteContent {
        let note = await NoteBuilder.build(file: file, index: 0, metaRepo: MetadataRepository(),
                                          transcriptRepo: TranscriptRepository(), includeSearchMetadata: false)
        let metadataURL = FileStore.metadataURL(forRecordingURL: file)
        let metadata = (try? Data(contentsOf: metadataURL)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        return StudioNoteContent(note: note, metadata: metadata, versions: await history.versions(for: file))
    }
}

enum StudioNoteEditError: LocalizedError {
    case changedElsewhere
    var errorDescription: String? { "Заметка изменилась в другом окне. Скопируйте свою правку и откройте заметку заново." }
}

enum StudioNoteWriter {
    /// Merge just the edited fields under the sidecar lock; never replace an entire card.
    static func save(_ text: String, content: StudioNoteContent, history: NoteVersionStore) async throws -> [NoteVersion] {
        let file = content.note.fileURL
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { metadata in
            var card = metadata["noteCard"] as? [String: Any] ?? [:]
            guard card["refined_text"] as? String == content.expectedRefinedText else {
                throw StudioNoteEditError.changedElsewhere
            }
            guard text != content.bodyText else { return false }
            if card.isEmpty {
                card = ["schema": Schemas.noteCard, "note_file": file.lastPathComponent,
                        "title": content.note.title ?? "", "summary": content.note.summary ?? "",
                        "processed_at": NSNull()]
            }
            card["refined_text"] = text
            card["refined_edited_at"] = Date().timeIntervalSinceReferenceDate
            metadata["noteCard"] = card
            return true
        }
        return await history.record(previous: content.bodyText, new: text, source: .manual, for: file)
    }
}
