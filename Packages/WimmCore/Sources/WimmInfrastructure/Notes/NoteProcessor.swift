import Foundation
import WimmDomain

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a NoteCard is successfully created or updated.
    /// userInfo contains: "fileURL": URL of the processed file
    public static let noteCardProcessed = Notification.Name("WimmNoteCardProcessed")
}

// MARK: - Processing Errors

/// Errors that can occur during note processing
public enum ProcessingError: Error, LocalizedError {
    case emptyContent
    case llmFailed(reason: String?)
    case persistenceFailed(Error)
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return "No content to process"
        case .llmFailed(let reason):
            return reason ?? "LLM failed to generate NoteCard"
        case .persistenceFailed(let error):
            return "Failed to save: \(error.localizedDescription)"
        case .invalidURL:
            return "Invalid file URL"
        }
    }
}

// MARK: - Note Processor

/// Unified note processing actor.
/// Single entry point for context building, LLM analysis, and persistence.
public actor NoteProcessor {
    public static let shared = NoteProcessor()

    private let fileRepository: FileRepository
    private let metadataRepository: MetadataRepository
    private let transcriptRepository: TranscriptRepository
    private let attachmentRepository: AttachmentRepository
    private let transcriptionGlossary: TranscriptionGlossary?
    private let personalGlossaryStore: PersonalGlossaryStore?

    public init(
        fileRepository: FileRepository = FileRepository(),
        metadataRepository: MetadataRepository = MetadataRepository(),
        transcriptRepository: TranscriptRepository = TranscriptRepository(),
        attachmentRepository: AttachmentRepository? = nil,
        transcriptionGlossary: TranscriptionGlossary? = .production,
        personalGlossaryStore: PersonalGlossaryStore? = .shared
    ) {
        self.fileRepository = fileRepository
        self.metadataRepository = metadataRepository
        self.transcriptRepository = transcriptRepository
        self.attachmentRepository =
            attachmentRepository ?? AttachmentRepository(metadataRepository: metadataRepository)
        self.transcriptionGlossary = transcriptionGlossary
        self.personalGlossaryStore = personalGlossaryStore
    }

    // MARK: - Main Entry Point
    /// One vocabulary read per analysis: the glossary that is sent (without
    /// sensitive terms in private mode) and the terms that are masked.
    private func resolvedVocabulary(privateMode: Bool, archiveSnapshot: Bool = true) async throws -> PersonalGlossaryStore.AnalysisVocabulary {
        guard let personalGlossaryStore else {
            return .init(glossary: transcriptionGlossary, pseudonymDictionary: [])
        }
        return try await personalGlossaryStore.analysisVocabulary(
            bundled: transcriptionGlossary, privateMode: privateMode, archiveSnapshot: archiveSnapshot)
    }

    private func makeClient(model: String, vocabulary: PersonalGlossaryStore.AnalysisVocabulary, privateMode: Bool) -> LLMJSONClient {
        LLMJSONClient(
            model: model,
            tracer: nil,
            capability: .think,
            transcriptionGlossary: vocabulary.glossary,
            personalGlossaryStore: nil,
            privateMode: privateMode,
            pseudonymDictionary: vocabulary.pseudonymDictionary
        )
    }

    /// Process a note file: build context, generate NoteCard via LLM, and persist it.
    /// - Parameters:
    ///   - file: The note file URL
    ///   - progress: Optional progress callback (0.0 - 1.0)
    /// - Returns: The generated NoteCard
    /// - Throws: ProcessingError if processing fails
    @discardableResult
    public func process(
        file: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        requestContext: [String: String]? = nil,
        markFallbackProcessed: Bool = false
    ) async throws -> NoteCard {
        progress?(0.1)

        // 0. Skip if NoteCard already fully processed (avoid redundant reprocessing)
        let existingCard = await metadataRepository.existingNoteCard(for: file)
        if let existing = existingCard, existing.isProcessed {
            log("NoteProcessor: Skipping \(file.lastPathComponent) — NoteCard already processed")
            progress?(1.0)
            return existing
        }

        // 1. Build unified context from all sources
        let context = await buildContext(for: file)

        guard !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.emptyContent
        }

        progress?(0.3)

        // 2. Generate NoteCard via LLM
        let privateMode = PrivateMode.isEnabled
        let vocabulary = try await resolvedVocabulary(privateMode: privateMode)
        let transcriptionGlossary = vocabulary.glossary
        let requestedModel = requestContext?["model"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let analysisModel = requestedModel.flatMap { $0.isEmpty ? nil : $0 } ?? Config.smartModel
        let client = makeClient(model: analysisModel, vocabulary: vocabulary, privateMode: privateMode)
        var card: NoteCard
        var glossaryWasApplied = false
        var pseudonymization: PseudonymizationReceipt?

        let localHypothesis = await transcriptRepository.localTranscriptText(for: file)
        if let generated = await LLMCostContext.with(
            noteFile: file.lastPathComponent, operation: .card,
            {
                await client.makeNoteCardResult(
                    noteId: UUID().uuidString,
                    transcript: context,
                    lang: nil,
                    fileName: file.lastPathComponent,
                    localTranscript: localHypothesis,
                    origin: requestContext?["origin"] ?? "NoteProcessor.process",
                    reason: requestContext?["reason"]
                )
            })
        {
            card = generated.card
            card.markProcessed()
            glossaryWasApplied = transcriptionGlossary != nil
            pseudonymization = generated.pseudonymization
        } else {
            log("NoteProcessor: LLM failed, using naive fallback for \(file.lastPathComponent)")
            let fallbackText = await transcriptRepository.textOfRecord(for: file) ?? context
            if let fallback = await metadataRepository.naiveNoteCard(for: file, transcript: fallbackText)
            {
                card = fallback
                // Keep normal fallback behavior for recovery queues, but allow reprocess
                // to finalize when LLM is unavailable.
                if markFallbackProcessed {
                    card.markProcessed()
                }
            } else {
                throw ProcessingError.llmFailed(
                    reason: "LLM failed and naive fallback validation failed")
            }
        }

        progress?(0.7)

        // 3. Ensure file name linkage
        card.note_file = file.lastPathComponent

        // 3a. Carry over what the user owns. The LLM response carries no flags
        // at all (see NoteCardExtractionResult), so anything not restored here
        // would silently reset to false on every reprocess.
        if let existing = existingCard {
            card.preserveUserState(from: existing)
        }

        // 4. Persist NoteCard
        await metadataRepository.upsertNoteCard(for: file, card: card, lang: nil)
        if glossaryWasApplied, let transcriptionGlossary {
            await metadataRepository.upsertMetadata(
                for: file,
                updates: [
                    MetadataKey.analysisGlossary.rawValue:
                        transcriptionGlossary.metadataReceipt
                ]
            )
        } else {
            await metadataRepository.upsertMetadata(for: file, updates: [MetadataKey.analysisGlossary.rawValue: NSNull()])
        }
        await stampPseudonymization(pseudonymization, for: file)

        // 4a. Notify UI that NoteCard was created
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .noteCardProcessed,
                object: nil,
                userInfo: ["fileURL": file]
            )
        }

        progress?(0.8)

        progress?(1.0)

        log("NoteProcessor: Completed processing for \(file.lastPathComponent)")
        return card
    }

    // MARK: - Reprocessing

    /// Force-reprocess a note: resets processed state, then runs full processing pipeline.
    /// This is the ONLY correct way to trigger reprocessing from UI or CLI.
    @discardableResult
    public func reprocess(
        file: URL,
        progress: (@Sendable (Double) -> Void)? = nil,
        requestContext: [String: String]? = nil
    ) async throws -> NoteCard {
        // Reset processed state so process() won't skip it
        if var existing = await metadataRepository.existingNoteCard(for: file) {
            existing.markForReprocessing()
            await metadataRepository.upsertNoteCard(for: file, card: existing, lang: nil)
            log("NoteProcessor: Reset processed state for \(file.lastPathComponent)")
        }

        return try await process(
            file: file,
            progress: progress,
            requestContext: requestContext,
            markFallbackProcessed: true
        )
    }

    // MARK: - Batch Retry for Missing/Unprocessed NoteCards

    /// Generate and persist a NoteCard without running assignments.
    /// Useful for backfill flows that only need metadata enrichment.
    @discardableResult
    public func makeNoteCard(
        file: URL,
        transcript: String,
        lang: String? = nil,
        context: [String: String]? = nil
    ) async throws -> NoteCard {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.emptyContent
        }

        let privateMode = PrivateMode.isEnabled
        let vocabulary = try await resolvedVocabulary(privateMode: privateMode)
        let transcriptionGlossary = vocabulary.glossary
        let client = makeClient(model: Config.smartModel, vocabulary: vocabulary, privateMode: privateMode)
        let localHypothesis = await transcriptRepository.localTranscriptText(for: file)
        guard
            let result = await LLMCostContext.with(
                noteFile: file.lastPathComponent, operation: .card,
                {
                    await client.makeNoteCardResult(
                        noteId: UUID().uuidString,
                        transcript: transcript,
                        lang: lang,
                        fileName: file.lastPathComponent,
                        localTranscript: localHypothesis,
                        origin: context?["origin"] ?? "NoteProcessor.makeNoteCard",
                        reason: context?["reason"]
                    )
                })
        else {
            throw ProcessingError.llmFailed(reason: nil)
        }

        var card = result.card
        card.note_file = file.lastPathComponent
        card.markProcessed()
        if let existing = await metadataRepository.existingNoteCard(for: file) {
            card.preserveUserState(from: existing)
        }
        await metadataRepository.upsertNoteCard(for: file, card: card, lang: lang)
        if let transcriptionGlossary {
            await metadataRepository.upsertMetadata(
                for: file,
                updates: [
                    MetadataKey.analysisGlossary.rawValue:
                        transcriptionGlossary.metadataReceipt
                ]
            )
        } else {
            await metadataRepository.upsertMetadata(for: file, updates: [MetadataKey.analysisGlossary.rawValue: NSNull()])
        }
        await stampPseudonymization(result.pseudonymization, for: file)

        return card
    }

    /// What a private-mode analysis of `file` would send: same context builder,
    /// vocabulary read, request builder and masking as `process`. No model call.
    public func privateEgressPreview(file: URL) async throws -> PrivateEgressPreview {
        let context = await buildContext(for: file, readOnly: true)
        let localHypothesis = await transcriptRepository.localTranscriptText(for: file)
        return try await privateEgressPreview(text: context, localTranscript: localHypothesis)
    }

    /// Local preview for supplied text (including CLI stdin). Uses the analysis
    /// request builder and one vocabulary read; no model call or library writes.
    public func privateEgressPreview(
        text: String, localTranscript: String? = nil, lang: String? = nil
    ) async throws -> PrivateEgressPreview {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProcessingError.emptyContent
        }
        let vocabulary = try await resolvedVocabulary(privateMode: true, archiveSnapshot: false)
        let client = makeClient(model: Config.smartModel, vocabulary: vocabulary, privateMode: true)
        return try await client.previewPrivateEgress(
            noteId: UUID().uuidString, transcript: text, lang: lang, localTranscript: localTranscript)
    }

    /// Receipt of a masked analysis; cleared when the card came from an unmasked call or a fallback.
    private func stampPseudonymization(_ receipt: PseudonymizationReceipt?, for file: URL) async {
        await metadataRepository.upsertMetadata(
            for: file,
            updates: [MetadataKey.analysisPseudonymization.rawValue: receipt?.metadata ?? NSNull()])
    }

    // MARK: - Context Building (SINGLE SOURCE OF TRUTH)

    /// Builds unified LLM context from transcript and attachments.
    /// This is the ONLY place where context is assembled.
    public func buildContext(for file: URL, readOnly: Bool = false) async -> String {
        let mainText = await transcriptRepository.textOfRecord(for: file) ?? ""
        let meta = await metadataRepository.metadata(for: file)
        let document = meta["document"] as? [String: Any]
        let ocr = meta["ocr"] as? [String: Any]
        let transcription = meta["transcription"] as? [String: Any]

        let transcriptionProvider = transcription?["provider"] as? String
        let transcriptionModel = transcription?["model"] as? String
        let documentTextProvider = document?[MetadataKey.textProvider.rawValue] as? String
        let documentTextModel = document?[MetadataKey.textModel.rawValue] as? String
        let ocrProvider = ocr?["provider"] as? String
        let ocrModel = ocr?["model"] as? String
        let attachments = await attachmentRepository.attachments(for: file, migrateLegacyKeys: !readOnly)

        return Self.buildContext(
            text: mainText,
            fileURL: file,
            transcriptionProvider: transcriptionProvider,
            transcriptionModel: transcriptionModel,
            extractionProvider: documentTextProvider ?? ocrProvider,
            extractionModel: documentTextModel ?? ocrModel,
            attachments: attachments
        )
    }

    /// Static variant for building context from provided components.
    public static func buildContext(
        text: String,
        fileURL: URL,
        transcriptionProvider: String? = nil,
        transcriptionModel: String? = nil,
        extractionProvider: String? = nil,
        extractionModel: String? = nil,
        attachments: [NoteAttachment]
    ) -> String {
        var parts: [String] = []
        let baseText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Main text with metadata
        if !baseText.isEmpty, !isPlaceholderText(baseText) {
            var meta: [String] = []

            if FileStore.isAudioFile(fileURL) {
                meta.append("source=audio_transcript")
                if let provider = transcriptionProvider, !provider.isEmpty {
                    meta.append("provider=\(provider)")
                }
                if let model = transcriptionModel, !model.isEmpty { meta.append("model=\(model)") }
            } else if NoteContent.kind(of: fileURL) == .text {
                meta.append("source=text_file")
            } else {
                meta.append("source=document_text")
                let provider = extractionProvider ?? transcriptionProvider
                let model = extractionModel ?? transcriptionModel
                if let provider, !provider.isEmpty { meta.append("provider=\(provider)") }
                if let model, !model.isEmpty { meta.append("model=\(model)") }
            }

            let header = "[MAIN_TEXT \(meta.joined(separator: " "))]"
            parts.append("\(header)\n\(baseText)")
        }

        // Attachments with OCR
        let baseLower = baseText.lowercased()
        for (i, attachment) in attachments.enumerated() {
            guard let ocr = attachment.extractedText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !ocr.isEmpty
            else { continue }

            // Skip if attachment text is duplicate of main text
            if shouldSkipAttachment(baseText: baseLower, attachmentText: ocr) { continue }

            var meta: [String] = ["type=\(attachment.type)"]
            if let provider = attachment.extractionProvider, !provider.isEmpty {
                meta.append("provider=\(provider)")
            }
            if let model = attachment.extractionModel, !model.isEmpty { meta.append("model=\(model)") }
            let header = "[ATTACHMENT_\(i + 1)_OCR \(meta.joined(separator: " "))]"
            parts.append("\(header)\n\(ocr)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private Helpers

    private static func isPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "no text recognized" || trimmed == "transcription failed"
            || trimmed == "no text found." || trimmed.hasPrefix("processing ")
    }

    private static func shouldSkipAttachment(baseText: String, attachmentText: String) -> Bool {
        let attachment = attachmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if attachment.count < 20 { return false }
        return baseText.contains(attachment.lowercased())
    }
}
