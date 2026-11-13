import Foundation

/// The note's body text and kind, by one rule set
/// (`docs/Note_Content_Resolver_Design_2026-11-10.md`). The only code that
/// reads a note's own file as its text.
///
/// - Kind: by extension, one table.
/// - Text notes (`txt`, `md`, `markdown`): the body is the file. A sidecar
///   `document.text` beside it is never the body — unless the file itself
///   could not be read (not UTF-8, not downloaded); then the copy is the best
///   text there is and `fileUnreadable` says so.
/// - Audio: `transcription.transcript`, then the legacy plain-string transcription.
/// - pdf/image/document: the same, then `document.text`.
///
/// The body is trimmed and nil when empty; display placeholders
/// ("No text recognized", …) are the caller's business.
public struct NoteContent: Sendable, Equatable {
    /// What a note is, judged once for every reader.
    public enum Kind: String, Sendable, Equatable {
        case audio, text, pdf, image, document
    }

    public enum BodySource: String, Sendable, Equatable {
        case typedFile, transcript, legacyTranscript, documentText
    }

    public let kind: NoteContent.Kind
    public let body: String?
    public let bodySource: BodySource?
    /// A text note's file exactly as read, untrimmed — for fingerprints and
    /// rewrites that must see the bytes. Nil for other kinds and when unreadable.
    public let fileText: String?
    /// A text note whose file exists in the listing but could not be read as
    /// UTF-8 (other encoding, not downloaded, gone). Not the same as empty.
    public let fileUnreadable: Bool

    public init(kind: NoteContent.Kind, body: String?, bodySource: BodySource?,
                fileText: String? = nil, fileUnreadable: Bool = false) {
        self.kind = kind
        self.body = body
        self.bodySource = bodySource
        self.fileText = fileText
        self.fileUnreadable = fileUnreadable
    }

    /// What a reader shows for a text note whose file could not be read and
    /// that has no sidecar copy either.
    public static let unreadableFilePlaceholder = "The note's file could not be read"

    /// The file itself is the note's text.
    public var isTypedFile: Bool { kind == .text }

    static let typedTextExtensions: Set<String> = ["txt", "md", "markdown"]
    static let imageExtensions: Set<String> = ["heic", "heif", "png", "jpg", "jpeg", "gif", "tiff", "webp", "bmp"]

    /// Kind by extension: the one table.
    public static func kind(of url: URL) -> NoteContent.Kind {
        if FileStore.isAudioFile(url) { return .audio }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if imageExtensions.contains(ext) { return .image }
        if typedTextExtensions.contains(ext) { return .text }
        return .document
    }

    /// Pure rule set. `typedFileText` is the file's content when the caller
    /// read it (only for a text anchor); nil means it could not be read.
    public static func resolve(anchor: URL, sidecar: [String: Any], typedFileText: String?) -> NoteContent {
        let kind = kind(of: anchor)
        func clean(_ value: Any?) -> String? {
            guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            return text
        }
        let documentText = clean((sidecar["document"] as? [String: Any])?["text"])
        if kind == .text {
            guard let typedFileText else {
                return NoteContent(kind: kind, body: documentText, bodySource: documentText == nil ? nil : .documentText,
                                   fileUnreadable: true)
            }
            let body = clean(typedFileText)
            return NoteContent(kind: kind, body: body, bodySource: body == nil ? nil : .typedFile, fileText: typedFileText)
        }
        let transcription = sidecar["transcription"]
        if let text = clean((transcription as? [String: Any])?["transcript"]) {
            return NoteContent(kind: kind, body: text, bodySource: .transcript)
        }
        if let text = clean(transcription) {
            return NoteContent(kind: kind, body: text, bodySource: .legacyTranscript)
        }
        if kind != .audio, let documentText {
            return NoteContent(kind: kind, body: documentText, bodySource: .documentText)
        }
        return NoteContent(kind: kind, body: nil, bodySource: nil)
    }

    /// `resolve` plus the one file read: the typed file, only for a text note.
    /// The sidecar is read only when needed: always for other kinds, for a text
    /// note only when its file could not be read.
    public static func load(anchor: URL, sidecar: @autoclosure () -> [String: Any]) -> NoteContent {
        guard kind(of: anchor) == .text else {
            return resolve(anchor: anchor, sidecar: sidecar(), typedFileText: nil)
        }
        if let text = try? String(contentsOf: anchor, encoding: .utf8) {
            return resolve(anchor: anchor, sidecar: [:], typedFileText: text)
        }
        return resolve(anchor: anchor, sidecar: sidecar(), typedFileText: nil)
    }
}
