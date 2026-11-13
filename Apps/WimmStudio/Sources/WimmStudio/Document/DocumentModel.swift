import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WimmDocumentUI
import WimmDomain
import WimmInfrastructure
import WimmSecretary

/// The personal document, its comment threads and block editing — the same
/// files and the same rules as the main app's Personal document window
/// (coordinated save that refuses to overwrite an outside change, threads in
/// `secretary/threads.jsonl` beside the Markdown), with a new UI on top.
@MainActor @Observable
final class DocumentModel {
    private(set) var document: PersonalDocument?
    private(set) var fileURL: URL?
    private(set) var threads: [DocumentCommentThread] = []
    private(set) var threadsByBlock: [Int: [DocumentCommentThread]] = [:]
    private(set) var detached: [DocumentCommentThread] = []
    var errorMessage: String?
    var isEditing = false
    @ObservationIgnored var onNoteCreated: (@MainActor (URL) -> Void)?

    let secretary = PersonalDocumentSecretary()
    var hasSecretaryWorkspace: Bool { fileURL.flatMap(SecretaryWorkspace.init(document:)) != nil }

    func runSecretary(_ kind: SecretaryRunKind) {
        guard let fileURL, !secretary.isRunning, !isEditing else { return }
        secretary.start(kind, document: fileURL) { [weak self] in await self?.load() }
    }

    @ObservationIgnored private var store: PersonalDocumentStore?
    @ObservationIgnored private var comments: DocumentCommentStore?
    @ObservationIgnored private var commentsModified: Date?
    @ObservationIgnored private var scoped: URL?
    private static let bookmarkKey = "WimmStudio.documentBookmark"

    init(url: URL? = nil) {
        if let url {
            open(url, remember: false)
            return
        }
        // Never auto-discover a real personal document from a test process.
        guard !StoragePaths.isTestProcess else { return }
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                open(url, remember: stale)
                return
            }
        }
        let conventional = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/_ME/docs/me_structured.md")
        if FileManager.default.fileExists(atPath: conventional.path) { open(conventional, remember: false) }
    }

    var commentsFileURL: URL? { comments?.location.fileURL }

    func choose() {
        guard !secretary.isRunning, !isEditing else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url, remember: true)
        Task { await load() }
    }

    private func open(_ url: URL, remember: Bool) {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = url.startAccessingSecurityScopedResource() ? url : nil
        fileURL = url
        store = PersonalDocumentStore(url: url)
        comments = DocumentCommentStore(document: url)
        commentsModified = nil
        document = nil
        threads = []; threadsByBlock = [:]; detached = []
        if remember, let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
    }

    func load() async {
        guard !isEditing, let store else { return }
        do {
            document = try await store.load()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
        await reloadComments(force: true)
    }

    // MARK: - Editing

    /// Replaces one block's Markdown. The save compares the file with what was
    /// loaded inside a coordinated write; an outside change is never overwritten.
    func replace(_ block: PersonalDocument.Block, with markdown: String) async -> Bool {
        guard !secretary.isRunning else { errorMessage = "The secretary is editing this document."; return false }
        guard let store, let document, let content = document.replacing(blockID: block.id, with: markdown) else { return false }
        guard content != document.text else { return true }
        do {
            try await store.save(content, expecting: document.text)
            self.document = PersonalDocument(text: content)
            errorMessage = nil
            place()
            return true
        } catch {
            errorMessage = error is PersonalDocumentError
                ? "The document changed on disk. Reload it before editing again."
                : error.localizedDescription
            return false
        }
    }

    // MARK: - Comments

    func target(for block: PersonalDocument.Block, selector: TextQuoteSelector) -> CommentTarget? {
        guard let fileURL, let document else { return nil }
        let section = document.section(of: block)
        return CommentTarget(documentURL: fileURL, section: section?.id, heading: section?.heading, selector: selector)
    }

    /// A reaction (any emoji) and/or a typed comment on a selection.
    func add(_ target: CommentTarget, text: String?, reaction: String?) async {
        guard let comments else { return }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(text ?? "").isEmpty || reaction != nil else { return }
        await append(CommentRecords.root(in: comments.location, target: target,
                                         text: (text ?? "").isEmpty ? nil : text, reaction: reaction))
    }

    /// Creates a new library note (`.txt` + `.meta.json` in `Recordings/`) attached
    /// right after `block`, and registers it in `threads.jsonl` (`via: "note:..."`)
    /// so it is immediately visible under the paragraph, in the HUD, and on the timeline.
    @discardableResult
    func createNote(after block: PersonalDocument.Block, text: String, plainBlockText: String) async -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, comments != nil else { return nil }
        do {
            guard let document, let fileURL else { return nil }
            let noteURL = try await DocumentNoteWriter.create(after: block, text: trimmed, plainBlockText: plainBlockText,
                                                               document: document, documentURL: fileURL)
            await reloadComments(force: true)
            onNoteCreated?(noteURL)
            return noteURL
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Selector anchored to the last sentence (or tail) of a paragraph block.
    static func tailSelector(of plainText: String) -> TextQuoteSelector {
        DocumentNoteWriter.tailSelector(of: plainText)
    }

    func reply(to thread: DocumentCommentThread, text: String) async {
        guard let comments else { return }
        await append(comments.newReply(to: thread.id, text: text, author: DocumentCommentAuthor.owner))
    }

    func setStatus(_ status: DocumentCommentStatus, of thread: DocumentCommentThread) async {
        guard let comments else { return }
        await append(comments.newStatus(of: thread.id, status, author: DocumentCommentAuthor.owner))
    }

    private func append(_ record: DocumentCommentRecord) async {
        guard let comments else { return }
        do {
            try await comments.append(record)
            await reloadComments(force: true)
        } catch { errorMessage = error.localizedDescription }
    }

    /// Rereads the threads file when its date changed (the secretary and the
    /// voice path append from outside this model).
    func reloadComments(force: Bool = false) async {
        guard let comments else { return }
        let modified = (try? comments.location.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || modified != commentsModified else { return }
        do {
            let snapshot = try await comments.load()
            commentsModified = snapshot.modified
            threads = snapshot.threads
            place()
        } catch { errorMessage = error.localizedDescription }
    }

    private func place() {
        guard let document else { return }
        let threads = threads
        Task {
            let placement = await Task.detached(priority: .userInitiated) { document.place(threads) }.value
            guard self.document?.text == document.text else { return }
            threadsByBlock = Dictionary(grouping: threads.filter { placement[$0.id] != nil }) { placement[$0.id]! }
            detached = threads.filter { placement[$0.id] == nil }
        }
    }
}
