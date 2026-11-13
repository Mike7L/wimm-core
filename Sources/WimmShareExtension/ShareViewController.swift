import UIKit
import UniformTypeIdentifiers

/// Receives content shared from other apps (Voice Memos, Photos, Files,
/// Safari, notes apps …) and drops it into the App Group inbox. The main app
/// drains the inbox on next activation (AppState.drainShareInbox) and runs
/// the regular import pipeline there — the extension itself stays free of
/// domain dependencies.
final class ShareViewController: UIViewController {
    /// Keep in sync with StoragePaths.baseDirectory() + AppState.shareInboxDirectory():
    /// the extension duplicates the two path constants instead of linking WimmDomain.
    private static let appGroupID = "group.com.wimm.app"

    /// Mirrors FileStore.supportedAudioExtensions + supportedDocumentExtensions;
    /// anything else is dropped by the drain anyway, so refuse it here where we
    /// can still tell the user that nothing was imported.
    private static let supportedExtensions: Set<String> = [
        // audio
        "m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "aac", "opus", "oga", "ogg",
        // documents
        "pdf", "png", "jpg", "jpeg", "heic", "gif", "webp",
        "txt", "md", "markdown", "log", "csv", "text", "docx", "doc",
    ]

    /// Types we can pull a file representation for, in preference order. The
    /// office identifiers have no UTType constant, so they are spelled out.
    private static let fileTypeIdentifiers: [String] = [
        UTType.audio.identifier,
        UTType.image.identifier,
        UTType.pdf.identifier,
        "org.openxmlformats.wordprocessingml.document",
        "com.microsoft.word.doc",
        UTType.text.identifier,
    ]

    private static var inboxDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("Wimm/ShareInbox", isDirectory: true)
    }

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didStart = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        statusLabel.text = NSLocalizedString("Importing into WIMM…", comment: "")
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
        spinner.startAnimating()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didStart else { return }
        didStart = true
        processAttachments()
    }

    private func processAttachments() {
        guard let inbox = Self.inboxDirectory else {
            finish(importedCount: 0)
            return
        }
        // Stage into a sibling tmp dir, then rename into the inbox so the
        // main app never sees half-copied files.
        let staging = inbox.deletingLastPathComponent()
            .appendingPathComponent("ShareInboxTmp", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)

        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        let attachments: [(provider: NSItemProvider, item: NSExtensionItem)] = items.flatMap { item in
            (item.attachments ?? []).map { ($0, item) }
        }
        guard !attachments.isEmpty else {
            finish(importedCount: 0)
            return
        }

        let group = DispatchGroup()
        let counter = ImportCounter()
        let sink = InboxSink(inbox: inbox, staging: staging)
        for (provider, item) in attachments {
            group.enter()
            Self.handle(provider: provider, item: item, sink: sink) { didImport in
                if didImport { counter.increment() }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.finish(importedCount: counter.value)
        }
    }

    /// Resolves one attachment into the inbox. Concrete media types win over
    /// the generic file/web URL fallbacks, so a shared photo lands as an image
    /// rather than as a link to it.
    private static func handle(
        provider: NSItemProvider,
        item: NSExtensionItem,
        sink: InboxSink,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        if let identifier = registeredIdentifier(of: provider, conformingTo: fileTypeIdentifiers) {
            let title = itemTitle(of: item)
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                guard let url else { completion(false); return }
                completion(sink.ingest(fileAt: url, preferredType: identifier, title: title))
            }
            return
        }

        // Registered only as a file URL (exotic audio formats, files whose UTI
        // we don't enumerate): accept it if the extension is importable.
        if let identifier = registeredIdentifier(of: provider, conformingTo: [UTType.fileURL.identifier]) {
            let title = itemTitle(of: item)
            provider.loadItem(forTypeIdentifier: identifier) { value, _ in
                guard let url = value as? URL else { completion(false); return }
                completion(sink.ingest(fileAt: url, preferredType: nil, title: title))
            }
            return
        }

        // Web links (Safari, mail, chat apps) become a small text note.
        if let identifier = registeredIdentifier(of: provider, conformingTo: [UTType.url.identifier]) {
            let title = itemTitle(of: item)
            provider.loadItem(forTypeIdentifier: identifier) { value, _ in
                guard let url = value as? URL else { completion(false); return }
                let body = [title, url.absoluteString].compactMap { $0 }.joined(separator: "\n")
                completion(sink.ingest(
                    text: body,
                    fileName: title ?? url.host ?? "Link",
                    provenance: ShareProvenance(link: url, title: title)
                ))
            }
            return
        }

        completion(false)
    }

    /// `loadItem`/`loadFileRepresentation` want an identifier the provider
    /// actually registered, so map our conformance list onto its own list
    /// (a shared .md file registers `net.daringfireball.markdown`, not `public.text`).
    private static func registeredIdentifier(
        of provider: NSItemProvider,
        conformingTo candidates: [String]
    ) -> String? {
        for candidate in candidates {
            guard let type = UTType(candidate) else { continue }
            let match = provider.registeredTypeIdentifiers.first { registered in
                registered == candidate || UTType(registered)?.conforms(to: type) == true
            }
            if let match { return match }
        }
        return nil
    }

    /// Page title for a shared link. Several apps put the bare URL into
    /// `attributedContentText`, which would only duplicate the link — skip it.
    private static func itemTitle(of item: NSExtensionItem) -> String? {
        let raw = item.attributedTitle?.string ?? item.attributedContentText?.string
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.lowercased().hasPrefix("http")
        else {
            return nil
        }
        return trimmed
    }

    static func isSupported(extension ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    private func finish(importedCount: Int) {
        spinner.stopAnimating()
        statusLabel.text = importedCount > 0
            ? NSLocalizedString("Saved to WIMM", comment: "")
            : NSLocalizedString("Nothing to import", comment: "")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }
}

/// Writes resolved attachments into the App Group inbox. Load handlers run on
/// background queues, so every entry point is thread-safe, and the provider's
/// temp file is consumed before the handler returns.
private final class InboxSink: @unchecked Sendable {
    private let inbox: URL
    private let staging: URL
    private let lock = NSLock()

    init(inbox: URL, staging: URL) {
        self.inbox = inbox
        self.staging = staging
    }

    func ingest(fileAt url: URL, preferredType: String?, title: String?) -> Bool {
        guard let fileName = Self.normalizedFileName(for: url, preferredType: preferredType) else {
            return false
        }
        let staged = staging.appendingPathComponent(UUID().uuidString + "-" + fileName)
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // Read the dates before copying: the copy gets fresh ones.
        let provenance = ShareProvenance(file: url, title: title)
        do {
            try FileManager.default.copyItem(at: url, to: staged)
            try move(staged: staged, fileName: fileName, provenance: provenance)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return false
        }
    }

    func ingest(text: String, fileName: String, provenance: ShareProvenance) -> Bool {
        let named = Self.sanitize(fileName) + ".txt"
        let staged = staging.appendingPathComponent(UUID().uuidString + "-" + named)
        do {
            try Data(text.utf8).write(to: staged, options: .atomic)
            try move(staged: staged, fileName: named, provenance: provenance)
            return true
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return false
        }
    }

    /// The provenance sidecar lands in the inbox before its file, so the
    /// drain never sees a file whose sidecar is still on the way. It is
    /// best-effort: a note without one is still a note.
    private func move(staged: URL, fileName: String, provenance: ShareProvenance) throws {
        lock.lock()
        defer { lock.unlock() }
        let destination = uniqueDestination(for: fileName)
        if let data = try? JSONSerialization.data(withJSONObject: provenance.json) {
            let stagedSidecar = staging.appendingPathComponent(UUID().uuidString + ".share.json")
            let sidecar = destination.appendingPathExtension("share.json")
            if (try? data.write(to: stagedSidecar, options: .atomic)) != nil {
                try? FileManager.default.moveItem(at: stagedSidecar, to: sidecar)
            }
        }
        try FileManager.default.moveItem(at: staged, to: destination)
    }

    /// Keeps the original name (it becomes the note title) but forces an
    /// extension the import pipeline understands, falling back to the UTI's
    /// preferred one when the provider handed us a bare temp file.
    private static func normalizedFileName(for url: URL, preferredType: String?) -> String? {
        let base = sanitize(url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension.lowercased()
        if ShareViewController.isSupported(extension: ext) {
            return base + "." + ext
        }
        guard
            let preferredType,
            let fallback = UTType(preferredType)?.preferredFilenameExtension?.lowercased(),
            ShareViewController.isSupported(extension: fallback)
        else {
            return nil
        }
        return base + "." + fallback
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\t"))
            .joined(separator: " ")
        let trimmed = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shared" : trimmed
    }

    private func uniqueDestination(for fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = inbox.appendingPathComponent(fileName)
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = inbox.appendingPathComponent("\(base)-\(attempt).\(ext)")
            attempt += 1
        }
        return candidate
    }
}

/// What the extension knows about a shared item before it is copied away:
/// the original name, the link, and the file's own dates. Written as
/// `<inbox file>.share.json`; AppState.drainShareInbox reads it (keep the
/// keys in sync with `NoteShareSource.InboxKey`). iOS gives an extension no
/// public way to learn which app shared the item, so there is no app field —
/// the drain infers one from the file's embedded metadata instead.
private struct ShareProvenance {
    var json: [String: Any] = [:]

    init(file url: URL, title: String?) {
        json["fileName"] = url.lastPathComponent
        if let title { json["title"] = title }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        if let created = values?.creationDate { json["fileCreated"] = Self.iso(created) }
        if let modified = values?.contentModificationDate { json["fileModified"] = Self.iso(modified) }
        json["sharedAt"] = Self.iso(Date())
    }

    init(link: URL, title: String?) {
        json["url"] = link.absoluteString
        if let title { json["title"] = title }
        json["sharedAt"] = Self.iso(Date())
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

/// Load handlers run on background queues; serialize the count.
private final class ImportCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
