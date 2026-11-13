import Foundation
import WimmDomain

public struct DocumentTextBackfillRequest: Sendable {
    public let apply: Bool
    public let onlyMissingNoteCard: Bool
    public let ocr: Bool
    public let limit: Int?
    public let maxPDFOCRPages: Int

    public init(
        apply: Bool = false,
        onlyMissingNoteCard: Bool = true,
        ocr: Bool = true,
        limit: Int? = nil,
        maxPDFOCRPages: Int = 50
    ) {
        self.apply = apply
        self.onlyMissingNoteCard = onlyMissingNoteCard
        self.ocr = ocr
        self.limit = limit
        self.maxPDFOCRPages = max(1, maxPDFOCRPages)
    }
}

public struct DocumentTextBackfillError: Codable, Sendable {
    public let file: String
    public let reason: String

    public init(file: String, reason: String) {
        self.file = file
        self.reason = reason
    }
}

public struct DocumentTextBackfillReport: Codable, Sendable {
    public let dryRun: Bool
    public let onlyMissingNoteCard: Bool
    public let ocrEnabled: Bool
    public let maxPDFOCRPages: Int
    public var scanned: Int
    public var skippedHasNoteCard: Int
    public var skippedHasTextAlready: Int
    public var extracted: Int
    public var emptyAfterExtraction: Int
    public var written: Int
    public var providers: [String: Int]
    public var errors: [DocumentTextBackfillError]

    public init(
        dryRun: Bool,
        onlyMissingNoteCard: Bool,
        ocrEnabled: Bool,
        maxPDFOCRPages: Int,
        scanned: Int = 0,
        skippedHasNoteCard: Int = 0,
        skippedHasTextAlready: Int = 0,
        extracted: Int = 0,
        emptyAfterExtraction: Int = 0,
        written: Int = 0,
        providers: [String: Int] = [:],
        errors: [DocumentTextBackfillError] = []
    ) {
        self.dryRun = dryRun
        self.onlyMissingNoteCard = onlyMissingNoteCard
        self.ocrEnabled = ocrEnabled
        self.maxPDFOCRPages = maxPDFOCRPages
        self.scanned = scanned
        self.skippedHasNoteCard = skippedHasNoteCard
        self.skippedHasTextAlready = skippedHasTextAlready
        self.extracted = extracted
        self.emptyAfterExtraction = emptyAfterExtraction
        self.written = written
        self.providers = providers
        self.errors = errors
    }
}

public struct DocumentTextBackfillService {
    private let fileRepository: any FileRepositoryProtocol
    private let metadataRepository: any MetadataRepositoryProtocol
    private let transcriptRepository: any TranscriptRepositoryProtocol
    private let importer: DocumentImporter

    public init(
        fileRepository: any FileRepositoryProtocol = FileRepository(),
        metadataRepository: any MetadataRepositoryProtocol = MetadataRepository(),
        transcriptRepository: any TranscriptRepositoryProtocol = TranscriptRepository(),
        importer: DocumentImporter? = nil
    ) {
        self.fileRepository = fileRepository
        self.metadataRepository = metadataRepository
        self.transcriptRepository = transcriptRepository
        self.importer = importer ?? DocumentImporter(
            fileRepository: fileRepository,
            attachmentRepository: AttachmentRepository(metadataRepository: metadataRepository),
            transcriptRepository: transcriptRepository,
            metadataRepository: metadataRepository
        )
    }

    public func run(_ request: DocumentTextBackfillRequest) async -> DocumentTextBackfillReport {
        let allFiles = await fileRepository.recordings(order: .descending)
        var report = DocumentTextBackfillReport(
            dryRun: !request.apply,
            onlyMissingNoteCard: request.onlyMissingNoteCard,
            ocrEnabled: request.ocr,
            maxPDFOCRPages: request.maxPDFOCRPages
        )

        for file in allFiles {
            if let limit = request.limit, report.scanned >= limit {
                break
            }

            guard shouldHandle(file: file) else { continue }
            report.scanned += 1

            if request.onlyMissingNoteCard {
                let card = await metadataRepository.existingNoteCard(for: file)
                if card != nil {
                    report.skippedHasNoteCard += 1
                    continue
                }
            }

            let existing = (await transcriptRepository.textOfRecord(for: file) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !existing.isEmpty, !isPlaceholderText(existing) {
                report.skippedHasTextAlready += 1
                continue
            }

            do {
                let extraction: DocumentExtraction?
                if request.apply {
                    extraction = try await importer.backfillDocumentText(
                        for: file,
                        allowOCR: request.ocr,
                        maxPDFOCRPages: request.maxPDFOCRPages
                    )
                } else {
                    extraction = try await importer.extractDocumentText(
                        for: file,
                        allowOCR: request.ocr,
                        maxPDFOCRPages: request.maxPDFOCRPages
                    )
                }

                guard let extraction else {
                    report.emptyAfterExtraction += 1
                    continue
                }

                let normalized = normalize(extraction.text)
                if normalized.isEmpty {
                    report.emptyAfterExtraction += 1
                    continue
                }

                report.extracted += 1
                report.providers[extraction.provider, default: 0] += 1
                if request.apply {
                    report.written += 1
                }
            } catch {
                report.errors.append(
                    DocumentTextBackfillError(
                        file: file.lastPathComponent,
                        reason: error.localizedDescription
                    )
                )
            }
        }

        return report
    }

    private func shouldHandle(file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        if FileStore.isAudioFile(file) { return false }
        if ext == "txt" { return true }
        return FileStore.supportedDocumentExtensions.contains(ext)
    }

    private func normalize(_ input: String) -> String {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isPlaceholderText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "no text recognized"
            || trimmed == "transcription failed"
            || trimmed == "no text found."
            || trimmed.hasPrefix("processing ")
            || trimmed.hasPrefix("import transcription failed")
    }
}
