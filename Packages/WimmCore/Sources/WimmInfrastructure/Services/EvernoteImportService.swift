import Foundation
import CryptoKit
import WimmDomain

// MARK: - Public summary

public struct EvernoteImportSummary: Sendable {
    /// Notes found across all parsed `.enex` files.
    public let found: Int
    /// Notes newly persisted as `CapturedNote`s.
    public let imported: Int
    /// Notes skipped because an identical note (same stable id) already exists.
    public let skipped: Int
    /// Attachment files (PDF/images/...) decoded and written to disk.
    public let attachments: Int
    /// Notes that failed to import.
    public let failed: Int

    public init(found: Int, imported: Int, skipped: Int, attachments: Int, failed: Int) {
        self.found = found
        self.imported = imported
        self.skipped = skipped
        self.attachments = attachments
        self.failed = failed
    }
}

// MARK: - Parsed model (intermediate)

/// A note ready to persist: ENML already converted to markdown and attachments
/// already written to disk. Holds no binary payload, so a whole file's worth of
/// these is cheap to keep in memory.
struct PreparedEvernoteNote: Sendable {
    let id: UUID
    let createdAt: Date
    let markdown: String
    let attachments: [PreparedEvernoteAttachment]
}

/// An attachment that was written to disk, ready to record in the note's sidecar
/// `attachments` array so the GUI treats it as a first-class attachment (playable
/// audio card, image thumbnail, …) rather than a bare inline Markdown link.
struct PreparedEvernoteAttachment: Sendable {
    /// Path relative to the storage root, e.g. `Attachments/Evernote/<id>/<file>`.
    let relativePath: String
    let mime: String
}

// MARK: - Importer

/// Imports Evernote `.enex` exports into the WIMM store as `CapturedNote`s.
///
/// Design notes:
/// - Parsing is **streaming** (`XMLParser` delegate). The 162 MB export must
///   never be loaded into a `String`; only one note's attachment bytes are held
///   in memory at a time.
/// - Each note gets a **deterministic id** derived from its title + created date
///   + a content prefix, so re-running the import (or overlapping exports) is
///   idempotent: an already-present note is skipped, never duplicated.
/// - `CapturedNote` has no attachments field, so attachment binaries are written
///   under `Attachments/Evernote/<id>/` and linked from the note's markdown.
public struct EvernoteImporter: Sendable {
    private let storageRoot: URL

    public init(storageRoot: URL) {
        self.storageRoot = storageRoot
    }

    /// Local-time `yyyy-MM-dd_HH-mm-ss` formatter matching `FileStore.dfFileName`,
    /// so the `Wimm_<stamp>` prefix lets the app recover the note's date.
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()


    /// Import every note from the given `.enex` files.
    ///
    /// Notes are written as real `.txt` recording files (so the GUI's note list,
    /// which enumerates recording media, picks them up) with a sibling
    /// `WimmMeta@v1` sidecar. Fresh imports are marked `pending` so the analysis
    /// queue produces their NoteCard.
    /// - Parameters:
    ///   - dryRun: when true, parse and report but write nothing.
    ///   - progress: called per note with `(index, total-so-far, title)`.
    public func importENEX(
        at fileURLs: [URL],
        dryRun: Bool = false,
        progress: (@Sendable (Int, String) -> Void)? = nil
    ) async throws -> EvernoteImportSummary {
        let recordingsDir = storageRoot.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: recordingsDir, withIntermediateDirectories: true)

        // Existing Evernote ids → dedup across files and across re-runs.
        var seen = Self.existingEvernoteIDs(in: recordingsDir)

        var found = 0
        var imported = 0
        var skipped = 0
        var attachments = 0
        var failed = 0

        for fileURL in fileURLs {
            let attachmentsRoot = storageRoot
                .appendingPathComponent("Attachments", isDirectory: true)
                .appendingPathComponent("Evernote", isDirectory: true)

            let parser = ENEXParser(
                attachmentsRoot: attachmentsRoot,
                existingIDs: seen,
                dryRun: dryRun
            )

            let prepared = parser.parse(fileURL: fileURL)
            found += parser.notesFound
            skipped += parser.skippedCount
            attachments += parser.attachmentsWritten

            for note in prepared {
                progress?(imported + 1, note.markdown.firstLineTitle)
                seen.insert(note.id)
                if dryRun {
                    imported += 1
                    continue
                }
                if Self.writeNote(note, to: recordingsDir, storageRoot: storageRoot) {
                    imported += 1
                } else {
                    failed += 1
                }
            }
        }

        return EvernoteImportSummary(
            found: found,
            imported: imported,
            skipped: skipped,
            attachments: attachments,
            failed: failed
        )
    }

    /// Writes one note as a `Wimm_<stamp>_<id8>.txt` recording file plus its
    /// `WimmMeta@v1` sidecar (status `pending`, source `Evernote`, stable id for
    /// dedup). Returns false on write failure.
    private static func writeNote(
        _ note: PreparedEvernoteNote, to recordingsDir: URL, storageRoot: URL
    ) -> Bool {
        let stamp = stampFormatter.string(from: note.createdAt)
        let short = String(note.id.uuidString.prefix(8)).lowercased()
        var base = "Wimm_\(stamp)_\(short)"
        var txtURL = recordingsDir.appendingPathComponent(base + ".txt")
        // Disambiguate the rare case of two notes sharing the same second + id prefix.
        var counter = 1
        while FileManager.default.fileExists(atPath: txtURL.path) {
            base = "Wimm_\(stamp)_\(short)_\(counter)"
            txtURL = recordingsDir.appendingPathComponent(base + ".txt")
            counter += 1
        }

        do {
            try note.markdown.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        var updates: [String: Any] = [
            "schema": Schemas.meta,
            "processingStatus": LegacyProcessingStatus.pending.rawValue,
            "importSource": "Evernote",
            "evernoteId": note.id.uuidString,
            "createdAt": ISO8601.string(from: note.createdAt),
        ]
        if !note.attachments.isEmpty {
            updates["attachments"] = attachmentEntries(note.attachments, storageRoot: storageRoot)
        }

        FileStore.upsertMetadata(for: txtURL, updates: updates)
        _ = FileStore.trySetFileDates(txtURL, created: note.createdAt, modified: note.createdAt)
        if !note.attachments.isEmpty {
            // One note = one media (2026-11-09): each attachment leaves the
            // sidecar at once and becomes a note of its own, linked from the text.
            do {
                _ = try AttachmentSplitMigration.splitFreshParent(
                    sidecar: FileStore.metadataURL(forRecordingURL: txtURL), library: storageRoot)
            } catch {
                log("[Evernote] split of \(txtURL.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Builds the sidecar `attachments` array in the exact shape the GUI reads
    /// (`AttachmentRepository`/`NoteBuilder.parseAttachments`): an absolute,
    /// percent-encoded `file://` URL plus a canonical `AttachmentType` string.
    private static func attachmentEntries(
        _ attachments: [PreparedEvernoteAttachment], storageRoot: URL
    ) -> [[String: Any]] {
        attachments.map { att in
            let absURL = storageRoot.appendingPathComponent(att.relativePath)
            return [
                "id": UUID().uuidString,
                "url": absURL.absoluteString,
                "type": AttachmentType(fromMIME: att.mime).rawValue,
            ]
        }
    }

    /// Scans existing sidecars for `evernoteId` values so re-importing the same
    /// export is idempotent.
    private static func existingEvernoteIDs(in recordingsDir: URL) -> Set<UUID> {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return [] }

        var ids = Set<UUID>()
        for url in files where url.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: url),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = dict["evernoteId"] as? String,
                  let id = UUID(uuidString: raw)
            else { continue }
            ids.insert(id)
        }
        return ids
    }
}

// MARK: - Deterministic id

enum EvernoteID {
    /// Stable UUID (v5-style) from an Evernote note's identifying fields.
    static func make(title: String, created: String, contentPrefix: String) -> UUID {
        let key = "evernote|\(title)|\(created)|\(contentPrefix)"
        let digest = SHA256.hash(data: Data(key.utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        ))
    }
}

// MARK: - Streaming ENEX parser

/// XMLParser delegate that walks an `.enex` document note-by-note. Attachment
/// bytes for the *current* note are buffered, decoded, written to disk on
/// `</note>`, then dropped — so peak memory stays bounded to one note.
final class ENEXParser: NSObject, XMLParserDelegate {
    private let attachmentsRoot: URL
    private let existingIDs: Set<UUID>
    private let dryRun: Bool
    private let fileManager = FileManager.default

    private(set) var notesFound = 0
    private(set) var skippedCount = 0
    private(set) var attachmentsWritten = 0

    /// A note captured during the streaming parse, before ENML→Markdown
    /// conversion. Conversion runs a nested `XMLParser`, which is illegal inside
    /// the outer parser's delegate callbacks (reentrancy), so it is deferred
    /// until `parse()` returns.
    private struct StagedNote {
        let id: UUID
        let createdAt: Date
        let title: String
        let rawENML: String
        let mediaMap: [String: ENMLAttachment]
        let attachments: [PreparedEvernoteAttachment]
    }
    private var staged: [StagedNote] = []

    // Current element + per-note accumulators.
    private var currentElement = ""
    private var title = ""
    private var created = ""
    private var content = ""

    private struct RawResource {
        var base64 = ""
        var mime = ""
        var fileName = ""
    }
    private var resources: [RawResource] = []
    private var current = RawResource()
    private var inResource = false

    init(attachmentsRoot: URL, existingIDs: Set<UUID>, dryRun: Bool) {
        self.attachmentsRoot = attachmentsRoot
        self.existingIDs = existingIDs
        self.dryRun = dryRun
    }

    func parse(fileURL: URL) -> [PreparedEvernoteNote] {
        staged.removeAll(keepingCapacity: true)
        guard let stream = InputStream(url: fileURL) else { return [] }
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        parser.parse()

        // ENML→Markdown conversion deferred to here: it spins up a nested
        // XMLParser, which must not run while the outer parser is active.
        return staged.map { note in
            let body = ENMLToMarkdown.convert(enml: note.rawENML, attachments: note.mediaMap)
            let heading = note.title.isEmpty ? "" : "# \(note.title)\n\n"
            return PreparedEvernoteNote(
                id: note.id,
                createdAt: note.createdAt,
                markdown: heading + body,
                attachments: note.attachments)
        }
    }

    // MARK: XMLParserDelegate

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        switch elementName {
        case "note":
            title = ""; created = ""; content = ""
            resources = []
        case "resource":
            inResource = true
            current = RawResource()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch currentElement {
        case "title": title += string
        case "created": created += string
        case "content": content += string
        case "data" where inResource: current.base64 += string
        case "mime" where inResource: current.mime += string
        case "file-name" where inResource: current.fileName += string
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        // `<content>` is wrapped in CDATA; XMLParser reports it here, not via
        // foundCharacters.
        guard currentElement == "content",
              let s = String(data: CDATABlock, encoding: .utf8) else { return }
        content += s
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch elementName {
        case "resource":
            resources.append(current)
            inResource = false
        case "note":
            finalizeNote()
        default:
            break
        }
        // Returning to a parent element: reset to a neutral name so stray
        // whitespace between siblings isn't appended to the last field.
        currentElement = ""
    }

    // MARK: Note finalization

    private func finalizeNote() {
        notesFound += 1

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(content.prefix(64))
        let id = EvernoteID.make(title: cleanTitle, created: created, contentPrefix: prefix)

        guard !existingIDs.contains(id) else {
            skippedCount += 1
            return
        }

        let createdDate = Self.parseENEXDate(created) ?? Date(timeIntervalSince1970: 0)

        // Decode + write this note's attachments, building hash → relative-path map.
        var mediaMap: [String: ENMLAttachment] = [:]
        var writtenAttachments: [PreparedEvernoteAttachment] = []
        if !resources.isEmpty {
            let noteDir = attachmentsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            var usedNames = Set<String>()
            for (index, res) in resources.enumerated() {
                guard let data = Data(base64Encoded: res.base64, options: .ignoreUnknownCharacters)
                else { continue }
                let md5 = Insecure.MD5.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
                let baseName = Self.attachmentFileName(
                    preferred: res.fileName, mime: res.mime, md5: md5, index: index)
                // Disambiguate identical file-names within the same note so later
                // resources don't overwrite earlier ones (and links stay distinct).
                let fileName = Self.uniqueName(baseName, used: &usedNames)
                let relPath = "Attachments/Evernote/\(id.uuidString)/\(fileName)"
                mediaMap[md5] = ENMLAttachment(
                    fileName: fileName, relativePath: relPath, mime: res.mime)

                if !dryRun {
                    do {
                        try fileManager.createDirectory(
                            at: noteDir, withIntermediateDirectories: true)
                        try data.write(to: noteDir.appendingPathComponent(fileName), options: .atomic)
                        // Only files that actually landed on disk become sidecar
                        // attachment entries, so a failed write never yields a
                        // broken attachment card.
                        writtenAttachments.append(
                            PreparedEvernoteAttachment(relativePath: relPath, mime: res.mime))
                    } catch {
                        // Best-effort: a failed attachment write still leaves the
                        // note importable with a dangling link.
                    }
                }
            }
        }
        attachmentsWritten += writtenAttachments.count

        staged.append(StagedNote(
            id: id,
            createdAt: createdDate,
            title: cleanTitle,
            rawENML: content,
            mediaMap: mediaMap,
            attachments: writtenAttachments))
    }

    // MARK: Helpers

    /// Parses Evernote's `yyyyMMdd'T'HHmmss'Z'` timestamps (e.g. `20181217T100322Z`).
    static func parseENEXDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return fmt.date(from: trimmed)
    }

    /// macOS caps file names at 255 UTF-8 bytes. Some Evernote exports (e.g. a
    /// forwarded Gmail attachment) carry a "file name" that's actually a
    /// multi-hundred-byte webmail URL; writing that verbatim throws and the
    /// attachment is silently dropped, leaving a dangling link in the note.
    private static let maxFileNameBytes = 200

    static func attachmentFileName(preferred: String, mime: String, md5: String, index: Int)
        -> String
    {
        // Sanitize: path separators and whitespace break relative Markdown links.
        let cleaned = preferred
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "(", with: "_")
            .replacingOccurrences(of: ")", with: "_")
        if !cleaned.isEmpty, cleaned.utf8.count <= maxFileNameBytes { return cleaned }
        let ext = Self.fileExtension(forMIME: mime)
        return "attachment_\(index)_\(md5.prefix(8))\(ext)"
    }

    /// Returns `name` if unused within `used`, otherwise inserts a numeric suffix
    /// before the extension (`foo.png` → `foo_1.png`). Mutates `used`.
    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        if !used.contains(name) { used.insert(name); return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem)_\(counter)" : "\(stem)_\(counter).\(ext)"
            if !used.contains(candidate) { used.insert(candidate); return candidate }
            counter += 1
        }
    }

    static func fileExtension(forMIME mime: String) -> String {
        switch mime.lowercased() {
        case "image/png": return ".png"
        case "image/jpeg", "image/jpg": return ".jpg"
        case "image/gif": return ".gif"
        case "image/heic": return ".heic"
        case "image/webp": return ".webp"
        case "application/pdf": return ".pdf"
        case "audio/mpeg", "audio/mp3": return ".mp3"
        case "audio/mp4", "audio/m4a": return ".m4a"
        case "audio/wav", "audio/x-wav": return ".wav"
        case "video/mp4": return ".mp4"
        default: return ""
        }
    }
}

// MARK: - ENML → Markdown

struct ENMLAttachment {
    let fileName: String
    let relativePath: String
    let mime: String
    var isImage: Bool { mime.lowercased().hasPrefix("image/") }
}

/// Converts a note's ENML (XHTML-in-CDATA) into Markdown. Uses an `XMLParser`
/// walk for correct text/`en-media` ordering and entity decoding, with a plain
/// tag-strip fallback for malformed content.
enum ENMLToMarkdown {
    static func convert(enml: String, attachments: [String: ENMLAttachment]) -> String {
        let trimmed = enml.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return "" }

        let walker = ENMLWalker(attachments: attachments)
        let parser = XMLParser(data: data)
        parser.delegate = walker
        if parser.parse() {
            return walker.finishedMarkdown()
        }
        return fallbackStrip(enml: trimmed, attachments: attachments)
    }

    /// Last-resort conversion when ENML isn't well-formed XML.
    static func fallbackStrip(enml: String, attachments: [String: ENMLAttachment]) -> String {
        var s = enml
        // Resolve en-media references to attachment links.
        s = s.replacingOccurrences(
            of: #"<en-media[^>]*hash="([0-9a-fA-F]+)"[^>]*/?>"#,
            with: "\n[[media:$1]]\n",
            options: .regularExpression)
        // Block boundaries → newlines.
        for tag in ["</div>", "</p>", "<br/>", "<br>", "</li>", "</h1>", "</h2>", "</h3>"] {
            s = s.replacingOccurrences(of: tag, with: "\n")
        }
        s = s.replacingOccurrences(of: "<li>", with: "- ")
        // Strip remaining tags.
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Resolve media placeholders.
        for (hash, att) in attachments {
            let link = att.isImage ? "![\(att.fileName)](\(att.relativePath))"
                                   : "[\(att.fileName)](\(att.relativePath))"
            s = s.replacingOccurrences(of: "[[media:\(hash)]]", with: link)
        }
        return collapseBlankLines(s)
    }

    static func decodeEntities(_ s: String) -> String {
        var r = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                   "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
        return r
    }

    static func collapseBlankLines(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// XMLParser delegate that emits Markdown as it walks an `<en-note>` tree.
final class ENMLWalker: NSObject, XMLParserDelegate {
    private let attachments: [String: ENMLAttachment]
    private var out = ""
    private var hrefStack: [String] = []
    private var linkText = ""
    private var inLink = false
    private var codeblockDepth = 0

    init(attachments: [String: ENMLAttachment]) {
        self.attachments = attachments
    }

    func finishedMarkdown() -> String {
        ENMLToMarkdown.collapseBlankLines(out)
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "br":
            out += "\n"
        case "div", "p":
            if let style = attributeDict["style"], style.contains("-en-codeblock:true") {
                codeblockDepth += 1
                out += "\n```\n"
            } else {
                out += "\n"
            }
        case "li":
            out += "\n- "
        case "ul", "ol":
            out += "\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            out += "\n\n## "
        case "a":
            inLink = true
            linkText = ""
            hrefStack.append(attributeDict["href"] ?? "")
        case "en-media":
            appendMedia(hash: attributeDict["hash"] ?? "", type: attributeDict["type"] ?? "")
        case "en-todo":
            let checked = (attributeDict["checked"] == "true")
            out += "\n- [\(checked ? "x" : " ")] "
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inLink {
            linkText += string
        } else {
            out += string
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch elementName {
        case "a":
            let href = hrefStack.popLast() ?? ""
            let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
            if href.isEmpty {
                out += text
            } else if text.isEmpty || text == href {
                out += href
            } else {
                out += "[\(text)](\(href))"
            }
            inLink = false
            linkText = ""
        case "div", "p":
            if codeblockDepth > 0 {
                out += "\n```\n"
                codeblockDepth -= 1
            } else {
                out += "\n"
            }
        default:
            break
        }
    }

    private func appendMedia(hash: String, type: String) {
        guard let att = attachments[hash.lowercased()] ?? attachments[hash] else {
            return
        }
        let link = att.isImage
            ? "![\(att.fileName)](\(att.relativePath))"
            : "[\(att.fileName)](\(att.relativePath))"
        out += "\n\(link)\n"
    }
}

// MARK: - Small helpers

extension String {
    /// First non-empty line with a leading `# ` stripped — a display title.
    var firstLineTitle: String {
        for line in split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            return t.hasPrefix("# ") ? String(t.dropFirst(2)) : t
        }
        return "(untitled)"
    }
}
