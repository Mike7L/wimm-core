import Foundation
import WimmInfrastructure
import Combine
import WimmTranscription
import WimmDomain

#if ENABLE_LOCAL_AI
import MLX

public func configureMLXForTests() {
    MLX.Device.setDefault(device: .cpu)
}
#else
public func configureMLXForTests() {}
#endif

// MARK: - Mock Repositories for Refactoring

public actor MockFileRepository: FileRepositoryProtocol {
    public var recordingsToReturn: [URL] = []
    public var assetsToReturn: [URL: FileRepository.FileAssets] = [:]

    public init() {}
    public func setRecordings(_ urls: [URL]) {
        self.recordingsToReturn = urls
    }
    
    public func recordings(order: FileRepository.Order, limit: Int?) -> [URL] {
        return recordingsToReturn
    }
    public func assets(for file: URL) -> FileRepository.FileAssets {
        return assetsToReturn[file] ?? FileRepository.FileAssets(screenshotURL: nil, metadataURL: nil)
    }
    public func invalidateCache() async {}
}

public actor MockMetadataRepository: @preconcurrency MetadataRepositoryProtocol {
    public var metadataToReturn: [URL: [String: Any]] = [:]
    public var transcriptionInfoToReturn: [URL: MetadataRepository.TranscriptionInfo] = [:]
    public var existingNoteCardToReturn: [URL: NoteCard] = [:]

    public init() {}
    public func transcriptionInfo(for file: URL) -> MetadataRepository.TranscriptionInfo {
        return transcriptionInfoToReturn[file] ?? MetadataRepository.TranscriptionInfo(provider: nil, model: nil, hasRaw: false)
    }
    public func metadata(for file: URL) -> sending [String: Any] {
        nonisolated(unsafe) let result = metadataToReturn[file] ?? [:]
        return result
    }
    public func metadataAndNoteCard(for file: URL) -> sending ([String: Any], NoteCard?) {
        nonisolated(unsafe) let meta = metadataToReturn[file] ?? [:]
        let card = existingNoteCardToReturn[file]
        return (meta, card)
    }
    public func existingNoteCard(for file: URL) -> NoteCard? {
        return existingNoteCardToReturn[file]
    }
    public func upsertMetadata(for file: URL, updates: [String: Any]) {
        var current = metadataToReturn[file] ?? [:]
        for (k, v) in updates { current[k] = v }
        metadataToReturn[file] = current
    }
    public func upsertNoteCard(for file: URL, card: NoteCard, lang: String?) async {}
    public func naiveNoteCard(for file: URL, transcript: String) async -> NoteCard? { return nil }
    #if SWIFTDATA_ENABLED && canImport(SwiftData) && !SPM_TESTS
    public func updateNoteMetaEntity(noteId: String, update: @escaping @Sendable (NoteMetaEntity) -> Void) async {}
    #endif
}

public actor MockTranscriptRepository: TranscriptRepositoryProtocol {
    public var textsToReturn: [URL: String] = [:]
    public var localTextsToReturn: [URL: String] = [:]
    public var recordedFailures: [URL: String] = [:]
    
    public init() {}
    public func textOfRecord(for file: URL) -> String? {
        return textsToReturn[file]
    }
    public func transcriptText(for file: URL) -> String? {
        return textsToReturn[file]
    }
    public func localTranscriptText(for file: URL) -> String? {
        return localTextsToReturn[file]
    }
    public func updateTranscriptText(text: String, duration: Double, to file: URL) async throws {
        textsToReturn[file] = text
    }
    public func writeFailurePlaceholder(duration: Double, file: URL, reasonLabel: String?, baseMessage: String) async {
        textsToReturn[file] = "\(baseMessage) (\(reasonLabel ?? "unknown"))"
    }
    public func recordTranscriptionFailure(for file: URL, reason: CoreTranscriptionFailureReason, underlying: Error?) async -> String {
        let msg = "Failure: \(reason)"
        recordedFailures[file] = msg
        return msg
    }
}

public actor MockAttachmentRepository: AttachmentRepositoryProtocol {
    public var attachmentsToReturn: [URL: [NoteAttachment]] = [:]
    public var savedOCRs: [(file: URL, text: String, provider: String, model: String, start: Date)] = []
    
    public init() {}
    public func attachments(for file: URL) -> [NoteAttachment] {
        return attachmentsToReturn[file] ?? []
    }
    public func saveOCR(for file: URL, text: String, provider: String, model: String, startedAt: Date) {
        savedOCRs.append((file, text, provider, model, startedAt))
    }
    public func upsertAttachments(for file: URL, attachments: [NoteAttachment]) async {
        // Mock overwrite or append logic
        attachmentsToReturn[file] = attachments
    }
    public func findParentSessionFile(for attachmentFile: URL) async -> URL? {
        return nil
    }
}

