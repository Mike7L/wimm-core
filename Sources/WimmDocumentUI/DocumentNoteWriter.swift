import Foundation
import WimmDomain
import WimmInfrastructure

/// Writes an ordinary durable library note and appends its document anchor.
public enum DocumentNoteWriter {
    public static func create(after block: PersonalDocument.Block, text: String, plainBlockText: String,
                              document: PersonalDocument, documentURL: URL) async throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let comments = DocumentCommentStore(document: documentURL)
        try FileStore.ensureDirectoryExists()
        try FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
        let identity = RecordingIdentity()
        let noteURL = FileStore.newRecordingURL(identity: identity, extension: "txt")
        try Data(trimmed.utf8).write(to: noteURL, options: .atomic)
        identity.persist(for: noteURL)

        let section = document.section(of: block)
        let selector = DocumentNoteWriter.tailSelector(of: plainBlockText)
        let firstLine = String(trimmed.split(whereSeparator: \.isNewline).first ?? Substring(trimmed)).prefix(80)
        FileStore.upsertMetadata(for: noteURL, updates: [
            "title": String(firstLine),
            "origin": [
                "source": "personal-document",
                "doc": comments.location.doc,
                "section": section?.id ?? "",
                "heading": section?.heading ?? "",
                "quote": selector.quote,
            ],
        ])

        let sidecarRel = StoragePaths.relativePath(for: FileStore.metadataURL(forRecordingURL: noteURL))
        let target = CommentTarget(documentURL: documentURL, section: section?.id, heading: section?.heading, selector: selector)
        let record = CommentRecords.root(
            in: comments.location,
            target: target,
            text: trimmed,
            reaction: "📝",
            via: "note:\(sidecarRel)"
        )
        try await comments.append(record)
        return noteURL
    }

    public static func tailSelector(of plainText: String) -> TextQuoteSelector {
        let ns = plainText as NSString
        guard ns.length > 0 else { return TextQuoteSelector(quote: "", prefix: "", suffix: "") }
        if let sentence = TextUnits.sentence(at: max(0, ns.length - 1), in: plainText) {
            return TextQuoteSelector(selecting: sentence, in: plainText)
        }
        let len = min(ns.length, 64)
        return TextQuoteSelector(selecting: NSRange(location: ns.length - len, length: len), in: plainText)
    }

}
