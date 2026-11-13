import Foundation
import WimmDomain

public protocol FileRepositoryProtocol: Sendable {
    func recordings(order: FileRepository.Order, limit: Int?) async -> [URL]
    func assets(for file: URL) async -> FileRepository.FileAssets
    func deleteRecordingAssets(at file: URL) async
    func recordingURLs(for noteIds: [String]) async -> [URL]
    func invalidateCache() async
}

public extension FileRepositoryProtocol {
    func recordings(order: FileRepository.Order = .ascending, limit: Int? = nil) async -> [URL] {
        return await recordings(order: order, limit: limit)
    }
}

@preconcurrency public protocol MetadataRepositoryProtocol: Sendable {
    func transcriptionInfo(for file: URL) async -> MetadataRepository.TranscriptionInfo
    func metadata(for file: URL) async -> sending [String: Any]
    func metadataAndNoteCard(for file: URL) async -> sending ([String: Any], NoteCard?)
    /// One sidecar read for journal construction. `searchText` is empty when
    /// the caller does not search metadata; it is the file's own UTF-8, not a
    /// second encoding of the parsed dictionary.
    func metadataForBuild(
        for file: URL,
        includeSearchText: Bool
    ) async -> sending (dictionary: [String: Any], noteCard: NoteCard?, searchText: String)
    func existingNoteCard(for file: URL) async -> NoteCard?
    func upsertMetadata(for file: URL, updates: [String: Any]) async
    func upsertNoteCard(for file: URL, card: NoteCard, lang: String?) async
    func naiveNoteCard(for file: URL, transcript: String) async -> NoteCard?
    func noteCardHasContent(_ card: NoteCard) async -> Bool
    #if SWIFTDATA_ENABLED && canImport(SwiftData) && !SPM_TESTS
    func updateNoteMetaEntity(noteId: String, update: @escaping @Sendable (NoteMetaEntity) -> Void) async
    #endif
}

public extension MetadataRepositoryProtocol {
    func metadataForBuild(
        for file: URL,
        includeSearchText: Bool
    ) async -> sending (dictionary: [String: Any], noteCard: NoteCard?, searchText: String) {
        let (dictionary, noteCard) = await metadataAndNoteCard(for: file)
        let searchText = includeSearchText ? NoteBuilder.searchableMetadataText(from: dictionary) : ""
        return (dictionary, noteCard, searchText)
    }
}

public protocol TranscriptRepositoryProtocol: Sendable {
    func textOfRecord(for file: URL) async -> String?
    func transcriptText(for file: URL) async -> String?
    func localTranscriptText(for file: URL) async -> String?
    func updateTranscriptText(text: String, duration: Double, to file: URL) async throws
    func writeFailurePlaceholder(duration: Double, file: URL, reasonLabel: String?, baseMessage: String) async
    @discardableResult func recordTranscriptionFailure(for file: URL, reason: CoreTranscriptionFailureReason, underlying: Error?) async -> String
}

public protocol AttachmentRepositoryProtocol: Sendable {
    func attachments(for file: URL) async -> [NoteAttachment]
    func appendAttachments(for file: URL, attachments: [NoteAttachment]) async
    func saveOCR(for file: URL, text: String, provider: String, model: String, startedAt: Date) async
    func findParentSessionFile(for attachmentFile: URL) async -> URL?
    func upsertAttachments(for file: URL, attachments: [NoteAttachment]) async
}

public protocol TrashRepositoryProtocol: Sendable {
    @discardableResult func moveToTrash(file: URL) async -> URL?
    @discardableResult func restoreFromTrash(file: URL) async -> URL?
    func permanentlyDelete(file: URL) async
    func emptyTrash() async
    func listTrash(order: FileRepository.Order) async -> [URL]
}
