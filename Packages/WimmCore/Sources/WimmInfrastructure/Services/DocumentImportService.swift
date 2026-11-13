import CoreGraphics
import Foundation
import WimmDomain
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

public typealias DocumentExtraction = TextExtractionResult

public struct DocumentImporter: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let ocrEngine: DocumentOCREngine
    private let provider: OCRProvider
    private let transport: LLMTransport
    private let fileRepository: any FileRepositoryProtocol
    private let attachmentRepository: any AttachmentRepositoryProtocol
    private let transcriptRepository: any TranscriptRepositoryProtocol
    private let metadataRepository: any MetadataRepositoryProtocol

    public static let imageExtensions: Set<String> = AttachmentTypeHelper.imageExtensions
    public static let textExtensions: Set<String> = AttachmentTypeHelper.textExtensions
    public static let officeExtensions: Set<String> = AttachmentTypeHelper.officeExtensions

    public init(
        ocrEngine: DocumentOCREngine = DocumentOCRConfig.engine,
        ocrProvider: OCRProvider? = nil,
        transport: LLMTransport = .shared,
        fileRepository: any FileRepositoryProtocol = FileRepository(),
        attachmentRepository: any AttachmentRepositoryProtocol = AttachmentRepository(
            metadataRepository: MetadataRepository()),
        transcriptRepository: any TranscriptRepositoryProtocol = TranscriptRepository(),
        metadataRepository: any MetadataRepositoryProtocol = MetadataRepository()
    ) {
        self.ocrEngine = ocrEngine
        self.transport = transport
        self.fileRepository = fileRepository
        self.attachmentRepository = attachmentRepository
        self.transcriptRepository = transcriptRepository
        self.metadataRepository = metadataRepository

        if let ocrProvider {
            self.provider = ocrProvider
        } else {
            switch ocrEngine {
            case .mlx:
                self.provider = LocalPhotoOCRProvider()
            case .vision:
                self.provider = VisionOCRProvider()
            case .gemini:
                self.provider = GeminiOCRProvider(
                    model: DocumentOCRConfig.geminiModel, transport: transport)
            case .miniCPM:
                self.provider = OpenRouterOCRProvider(
                    model: DocumentOCRConfig.openRouterModel, transport: transport)
            }
        }
    }

    public func extractTextFromImage(at url: URL) async throws -> String {
        if ocrEngine == .mlx { return try await provider.performOCR(on: LocalPhotoInput.load(url)) }
        #if canImport(AppKit)
        guard let image = NSImage(contentsOf: url),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return "" }
        #elseif canImport(UIKit)
        guard let image = UIImage(contentsOfFile: url.path),
            let cgImage = image.cgImage
        else { return "" }
        #else
        return ""
        #endif

        return try await provider.performOCR(on: cgImage)
    }

    /// Re-runs text extraction for a document note (PDF, image, office, text).
    ///
    /// Only the *derived* first-page preview is discarded so it gets rebuilt;
    /// the note file, its metadata (sync ID, NoteCard, attachments) and its
    /// screenshots must survive a retry. For an image note the "preview" URL
    /// resolves to the note file itself, so nothing is deleted there.
    public func retranscribeDocument(at fileURL: URL, processor: NoteProcessor? = .shared) async -> Bool {
        let preview = FileStore.screenshotURL(forRecordingURL: fileURL)
        if preview.standardizedFileURL != fileURL.standardizedFileURL,
            !Self.imageExtensions.contains(fileURL.pathExtension.lowercased())
        {
            try? fileManager.removeItem(at: preview)
            await fileRepository.invalidateCache()
        }
        return await transcribeDocument(at: fileURL, sourceURL: nil, processor: processor)
    }

    /// `generatesPreview: false` for a PDF that is not a note of its own (an
    /// attachment): its `{base}.heic` preview would only be litter there.
    public func extractText(
        from pdfURL: URL, allowOCR: Bool = true, maxOCRPages: Int? = nil, generatesPreview: Bool = true
    ) async throws -> DocumentExtraction {
        let sourceHash = try ImageBatchRecord.hash(pdfURL)
        guard let doc = PDFDocument(url: pdfURL) else {
            throw NSError(
                domain: "WimmDocumentImport", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open PDF"])
        }
        if generatesPreview { generatePreviewIfNeeded(for: doc, fileURL: pdfURL) }
        let pageCount = doc.pageCount
        var pages: [DocumentPageEvidence] = []
        var usedOCR = false
        let limit = maxOCRPages.map { min(max(1,$0),pageCount) } ?? pageCount
        for index in 0..<pageCount {
            guard let page = doc.page(at:index) else {
                pages.append(.init(page:index+1,text:"",provider:"unknown",error:"pdf_page_unavailable"));continue
            }
            let text = page.string?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            if !text.isEmpty { pages.append(.init(page:index+1,text:text,provider:"pdfkit"));continue }
            guard allowOCR, index < limit else {
                pages.append(.init(page:index+1,text:"",provider:"unknown",error:allowOCR ? "ocr_page_budget_exceeded" : "ocr_not_requested"));continue
            }
            guard let image = makePageCGImage(page) else {
                pages.append(.init(page:index+1,text:"",provider:"unknown",error:"pdf_page_render_failed"));continue
            }
            do {
                usedOCR = true
                if provider is VisionOCRProvider || provider is LocalPhotoOCRProvider {
                    let record = try await ImageUnderstanding.extractRaster(image,source:pdfURL,sourceSHA256:sourceHash,engine:ocrEngine)
                    pages.append(.init(page:index+1,text:record.text,provider:record.provider,analysis:record))
                } else { pages.append(.init(page:index+1,text:try await provider.performOCR(on:image),provider:ocrEngine.rawValue)) }
            } catch is CancellationError { throw CancellationError() }
            catch { pages.append(.init(page:index+1,text:"",provider:ocrEngine.rawValue,error:"ocr_failed:\(String(describing:type(of:error)))")) }
        }
        guard try ImageBatchRecord.hash(pdfURL) == sourceHash else { throw CocoaError(.fileReadUnknown) }
        let combinedText = pages.filter { !$0.text.isEmpty }.map { "[page \($0.page)]\n" + $0.text }.joined(separator:"\n\n")
        if !usedOCR {
            return TextExtractionResult(text:combinedText,provider:TextExtractionProvider.pdfKit,model:"PDFKit",
                pageCount:pageCount,pages:pages,sourceSHA256:sourceHash)
        }
        let modelName: String
        let providerName: String
        switch ocrEngine {
        case .mlx:
            providerName = LocalPhotoModel.provider
            modelName = LocalPhotoModel.identifier + " + Apple Vision"
        case .vision:
            providerName = TextExtractionProvider.vision
            modelName = "VNRecognizeText"
        case .gemini:
            providerName = TextExtractionProvider.gemini
            modelName = DocumentOCRConfig.geminiModel
        case .miniCPM:
            providerName = TextExtractionProvider.openRouter
            modelName = DocumentOCRConfig.openRouterModel
        }

        return TextExtractionResult(
            text: combinedText, provider: providerName, model: modelName, pageCount: pageCount,pages:pages,sourceSHA256:sourceHash)
    }

    public func backfillDocumentText(
        for fileURL: URL,
        sourceURL: URL? = nil,
        allowOCR: Bool = true,
        maxPDFOCRPages: Int? = nil
    ) async throws -> DocumentExtraction? {
        guard
            let extraction = try await extractDocumentText(
                for: fileURL,
                allowOCR: allowOCR,
                maxPDFOCRPages: maxPDFOCRPages
            )
        else {
            return nil
        }
        let normalized = normalize(extraction.text)
        if let pages = extraction.pages, normalized.isEmpty {
            try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:fileURL)) { meta in
                var doc = meta["document"] as? [String:Any] ?? [:]
                try DocumentPageEvidence.store(pages,sourceSHA256:extraction.sourceSHA256,in:&doc)
                meta["document"] = doc;return true
            }
        }
        if let image = extraction.imageAnalysis, normalized.isEmpty {
            try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:fileURL)) { meta in
                var doc = meta["document"] as? [String:Any] ?? [:]
                try ImageAnalysisHistory.store(image,in:&doc);meta["document"] = doc;return true
            }
        }
        guard !normalized.isEmpty else { return nil }

        var docMeta =
            (await metadataRepository.metadata(for: fileURL))[MetadataKey.document.rawValue]
            as? [String: Any] ?? [:]
        if let pages = extraction.pages { try DocumentPageEvidence.store(pages,sourceSHA256:extraction.sourceSHA256,in:&docMeta) }
        archivePreviousExtractionRun(
            in: &docMeta,
            replacingWith: normalized,
            textKey: MetadataKey.text.rawValue,
            providerKey: MetadataKey.textProvider.rawValue,
            modelKey: MetadataKey.textModel.rawValue
        )
        docMeta[MetadataKey.text.rawValue] = normalized
        docMeta[MetadataKey.textProvider.rawValue] = extraction.provider
        if let image = extraction.imageAnalysis { try ImageAnalysisHistory.store(image,in:&docMeta) }
        if let model = extraction.model, !model.isEmpty {
            docMeta[MetadataKey.textModel.rawValue] = model
        }
        if let pageCount = extraction.pageCount {
            docMeta[MetadataKey.pageCount.rawValue] = pageCount
        }
        if let sourceURL {
            docMeta[MetadataKey.sourcePath.rawValue] = sourceURL.path
        }
        await metadataRepository.upsertMetadata(
            for: fileURL,
            updates: [
                MetadataKey.document.rawValue: docMeta
            ])

        do {
            try await transcriptRepository.updateTranscriptText(
                text: normalized,
                duration: estimateDuration(for: normalized),
                to: fileURL
            )
        } catch {
            // Metadata backfill remains useful even if transcript write fails.
        }

        return TextExtractionResult(
            text: normalized,
            provider: extraction.provider,
            model: extraction.model,
            pageCount: extraction.pageCount
        )
    }

    public func extractDocumentText(
        for fileURL: URL,
        allowOCR: Bool = true,
        maxPDFOCRPages: Int? = nil
    ) async throws -> DocumentExtraction? {
        let ext = fileURL.pathExtension.lowercased()
        let extraction: DocumentExtraction

        if ext == "txt" {
            guard let text = readTextFile(from: fileURL) else { return nil }
            extraction = TextExtractionResult(
                text: text,
                provider: TextExtractionProvider.plainText,
                model: nil,
                pageCount: nil
            )
        } else if ext == "pdf" {
            extraction = try await extractText(
                from: fileURL,
                allowOCR: allowOCR,
                maxOCRPages: maxPDFOCRPages
            )
        } else if Self.imageExtensions.contains(ext) {
            guard allowOCR else { return nil }
            if provider is VisionOCRProvider || provider is LocalPhotoOCRProvider {
                let record = try await ImageUnderstanding.extract(fileURL,engine:ocrEngine)
                return TextExtractionResult(text:record.text,provider:record.provider,model:record.model,imageAnalysis:record)
            }
            let text = try await extractTextFromImage(at: fileURL)
            let providerName: String
            let modelName: String
            switch ocrEngine {
            case .mlx:
                providerName = LocalPhotoModel.provider
                modelName = LocalPhotoModel.identifier + " + Apple Vision"
            case .vision:
                providerName = TextExtractionProvider.vision
                modelName = "VNRecognizeText"
            case .gemini:
                providerName = TextExtractionProvider.gemini
                modelName = DocumentOCRConfig.geminiModel
            case .miniCPM:
                providerName = TextExtractionProvider.openRouter
                modelName = DocumentOCRConfig.openRouterModel
            }
            extraction = TextExtractionResult(
                text: text,
                provider: providerName,
                model: modelName,
                pageCount: nil
            )
        } else if Self.officeExtensions.contains(ext) {
            let text = try await extractTextFromOffice(at: fileURL)
            extraction = TextExtractionResult(
                text: text,
                provider: "native",
                model: "NSAttributedString",
                pageCount: nil
            )
        } else if Self.textExtensions.contains(ext) {
            guard let text = readTextFile(from: fileURL) else { return nil }
            extraction = TextExtractionResult(
                text: text,
                provider: TextExtractionProvider.plainText,
                model: nil,
                pageCount: nil
            )
        } else {
            return nil
        }

        return extraction
    }

    private func extractTextFromOffice(at url: URL) async throws -> String {
        #if canImport(AppKit)
        try await Task.detached {
            let ext = url.pathExtension.lowercased()
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]

            if ext == "doc" {
                options[.documentType] = NSAttributedString.DocumentType.docFormat
            } else {
                options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
            }

            let str = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            return str.string
        }.value
        #else
        throw NSError(
            domain: "WimmDocumentImport",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Office text extraction is not supported on this platform"]
        )
        #endif
    }

    /// Extracts text from any supported document note and persists it.
    /// Routing is by file type — PDFs go through PDFKit/OCR, images through
    /// OCR, office/text files through their own readers.
    private func transcribeDocument(at fileURL: URL, sourceURL: URL?, processor: NoteProcessor?)
        async -> Bool
    {
        let startedAt = Date()
        let extraction: DocumentExtraction
        do {
            guard
                let extracted = try await extractDocumentText(
                    for: fileURL, allowOCR: ProcessingCfg.ocrEnabled)
            else {
                let label = await transcriptRepository.recordTranscriptionFailure(
                    for: fileURL, reason: .decoding,
                    underlying: NSError(
                        domain: "WimmDocumentImport", code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unsupported document type: .\(fileURL.pathExtension.lowercased())"
                        ]))
                await transcriptRepository.writeFailurePlaceholder(
                    duration: 1, file: fileURL, reasonLabel: label,
                    baseMessage: "Import transcription failed")
                return false
            }
            extraction = extracted
        } catch {
            let ns = error as NSError
            let reason: CoreTranscriptionFailureReason
            if ns.domain == NSURLErrorDomain {
                reason = .network
            } else if ns.domain == ErrorDomain.badStatus {
                reason = .badStatus
            } else {
                reason = .decoding
            }
            let label = await transcriptRepository.recordTranscriptionFailure(
                for: fileURL, reason: reason, underlying: error)
            await transcriptRepository.writeFailurePlaceholder(
                duration: 1, file: fileURL, reasonLabel: label,
                baseMessage: "Import transcription failed")
            return false
        }

        let existingMeta = await metadataRepository.metadata(for: fileURL)
        var docMeta = existingMeta[MetadataKey.document.rawValue] as? [String: Any] ?? [:]
        if let image = extraction.imageAnalysis { try? ImageAnalysisHistory.store(image,in:&docMeta) }
        if let pages = extraction.pages { try? DocumentPageEvidence.store(pages,sourceSHA256:extraction.sourceSHA256,in:&docMeta) }
        if let pageCount = extraction.pageCount {
            docMeta[MetadataKey.pageCount.rawValue] = pageCount
        }
        if let sourceURL {
            docMeta[MetadataKey.sourcePath.rawValue] = sourceURL.path
        }
        if !docMeta.isEmpty {
            FileStore.upsertMetadata(for: fileURL, updates: [MetadataKey.document.rawValue: docMeta])
        }

        let trimmed = extraction.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let existingText = (docMeta[MetadataKey.text.rawValue] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existingText.isEmpty && !TranscriptRuns.hasSuccessfulRun(forNoteFile: fileURL) {
                let label = await transcriptRepository.recordTranscriptionFailure(
                    for: fileURL, reason: .empty, underlying: nil)
                await transcriptRepository.writeFailurePlaceholder(
                    duration: 1, file: fileURL, reasonLabel: label, baseMessage: "No text recognized")
            }
            return false
        }

        var docMetaWithText = docMeta
        archivePreviousExtractionRun(
            in: &docMetaWithText,
            replacingWith: trimmed,
            textKey: MetadataKey.text.rawValue,
            providerKey: MetadataKey.textProvider.rawValue,
            modelKey: MetadataKey.textModel.rawValue
        )
        docMetaWithText[MetadataKey.text.rawValue] = trimmed
        docMetaWithText[MetadataKey.textProvider.rawValue] = extraction.provider
        docMetaWithText[MetadataKey.textModel.rawValue] = extraction.model
        docMetaWithText["startedAt"] = ISO8601.string(from: startedAt)
        FileStore.upsertMetadata(
            for: fileURL, updates: [MetadataKey.document.rawValue: docMetaWithText])

        let duration = estimateDuration(for: trimmed)
        recordRunSuccess(
            file: fileURL,
            provider: extraction.provider,
            model: extraction.model ?? "unknown",
            audioDuration: duration,
            startedAt: startedAt,
            elapsedSeconds: Date().timeIntervalSince(startedAt),
            transcript: trimmed,
            speechStatus: .speech,
            rawResponse: nil
        )

        if let processor {
            _ = try? await processor.makeNoteCard(file: fileURL, transcript: trimmed, lang: nil)
        }

        return true
    }

    private func performOCR(on doc: PDFDocument, maxPages: Int?) async -> String {
        var blocks: [String] = []
        let totalPages = doc.pageCount
        let upperBound = maxPages.map { min(max(1, $0), totalPages) } ?? totalPages
        for index in 0..<upperBound {
            guard let page = doc.page(at: index),
                let cgImage = makePageCGImage(page)
            else { continue }
            do {
                let text = try await provider.performOCR(on: cgImage)
                if !text.isEmpty {
                    blocks.append(text)
                }
            } catch {
                print("OCR failed for page \(index): \(error)")
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    private func makePageCGImage(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(
            width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = page.thumbnail(of: size, for: .mediaBox)
        #if canImport(AppKit)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif canImport(UIKit)
        return image.cgImage
        #else
        return nil
        #endif
    }

    private func generatePreviewIfNeeded(for doc: PDFDocument, fileURL: URL) {
        let previewURL = FileStore.screenshotURL(forRecordingURL: fileURL)
        guard !fileManager.fileExists(atPath: previewURL.path) else { return }
        guard let page = doc.page(at: 0),
            let cgImage = makePageCGImage(page, scale: 1.5)
        else { return }

        let destUTI = UTType.heic.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(previewURL as CFURL, destUTI, 1, nil)
        else { return }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.78]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
    }

    private func estimateDuration(for text: String) -> Double {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let minutes = Double(words) / 180.0
        return max(10, min(3600, minutes * 60))
    }

    private func normalize(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readTextFile(from url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        if let text = try? String(contentsOf: url, encoding: .utf16) { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) { return text }
        return nil
    }

}
