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
    private let transcriptionGlossary: TranscriptionGlossary?
    private let personalGlossaryStore: PersonalGlossaryStore?

    public init(
        fileRepository: FileRepository = FileRepository(),
        metadataRepository: MetadataRepository = MetadataRepository(),
        transcriptRepository: TranscriptRepository = TranscriptRepository(),
        transcriptionGlossary: TranscriptionGlossary? = .production,
        personalGlossaryStore: PersonalGlossaryStore? = .shared
    ) {
        self.fileRepository = fileRepository
        self.metadataRepository = metadataRepository
        self.transcriptRepository = transcriptRepository
        self.transcriptionGlossary = transcriptionGlossary
        self.personalGlossaryStore = personalGlossaryStore
    }

    // MARK: - Main Entry Point
    /// One vocabulary read per analysis: the glossary that is sent.
    private func resolvedGlossary() async throws -> TranscriptionGlossary? {
        guard let personalGlossaryStore else { return transcriptionGlossary }
        return try await personalGlossaryStore.analysisGlossary(bundled: transcriptionGlossary)
    }

    private func makeClient(model: String, glossary: TranscriptionGlossary?) -> LLMJSONClient {
        LLMJSONClient(
            model: model,
            tracer: nil,
            capability: .think,
            transcriptionGlossary: glossary,
            personalGlossaryStore: nil
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
        let transcriptionGlossary = try await resolvedGlossary()
        let requestedModel = requestContext?["model"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let analysisModel = requestedModel.flatMap { $0.isEmpty ? nil : $0 } ?? Config.smartModel
        let client = makeClient(model: analysisModel, glossary: transcriptionGlossary)
        var card: NoteCard
        var glossaryWasApplied = false

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
        await clearLegacyPseudonymization(for: file)

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

        let transcriptionGlossary = try await resolvedGlossary()
        let client = makeClient(model: Config.smartModel, glossary: transcriptionGlossary)
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
        await clearLegacyPseudonymization(for: file)

        return card
    }

    /// A fresh analysis is never masked; drop a stale receipt from the removed pseudonymization.
    private func clearLegacyPseudonymization(for file: URL) async {
        await metadataRepository.upsertMetadata(
            for: file, updates: [MetadataKey.analysisPseudonymization.rawValue: NSNull()])
    }

    // MARK: - Context Building (SINGLE SOURCE OF TRUTH)

    /// Builds unified LLM context from the note's own text (one note = one media).
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
        // A recording's screenshot is part of the same note: its OCR text goes along.
        let screenshotText = FileStore.isAudioFile(file) ? ocr?["text"] as? String : nil

        return Self.buildContext(
            text: mainText,
            fileURL: file,
            transcriptionProvider: transcriptionProvider,
            transcriptionModel: transcriptionModel,
            extractionProvider: documentTextProvider ?? ocrProvider,
            extractionModel: documentTextModel ?? ocrModel,
            screenshotText: screenshotText,
            screenshotProvider: ocrProvider,
            screenshotModel: ocrModel
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
        screenshotText: String? = nil,
        screenshotProvider: String? = nil,
        screenshotModel: String? = nil
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

        if let shot = screenshotText?.trimmingCharacters(in: .whitespacesAndNewlines), !shot.isEmpty,
           !(shot.count >= 20 && baseText.lowercased().contains(shot.lowercased())) {
            var meta = ["type=screenshot"]
            if let provider = screenshotProvider, !provider.isEmpty { meta.append("provider=\(provider)") }
            if let model = screenshotModel, !model.isEmpty { meta.append("model=\(model)") }
            parts.append("[SCREENSHOT_OCR \(meta.joined(separator: " "))]\n\(shot)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Private Helpers

    private static func isPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "no text recognized" || trimmed == "transcription failed"
            || trimmed == "no text found." || trimmed.hasPrefix("processing ")
    }
}
