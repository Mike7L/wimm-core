import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Protocol

public protocol FileStoreProtocol {
    func baseDirectory() -> URL
    func recordingsDirectory() -> URL
    func audioDirectory() -> URL
    func metadataURL(forRecordingURL recording: URL) -> URL
    func relativePath(for url: URL) -> String
    func resolveRelativePath(_ path: String) -> URL
    func ensureDirectoryExists() throws
    func isAudioFile(_ url: URL) -> Bool
    func isAttachmentFile(_ url: URL) -> Bool
    func isSupportedRecordingFile(_ url: URL) -> Bool
}

// MARK: - Default Implementation

public final class DefaultFileStore: FileStoreProtocol, @unchecked Sendable {
    public static let shared = DefaultFileStore()
    private init() {}

    private let dfFileName: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()
    private let dfMinuteFileName: DateFormatter = {
        let f = DateFormatter()
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        f.isLenient = false
        return f
    }()
    private let dfStreamFileName: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd_HHmmss"; return f
    }()
    private let dfClock: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm:ss"; return f
    }()
    private let dfFull: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd • HH:mm:ss"; return f
    }()

    public func fullDateTime(_ date: Date) -> String { dfFull.string(from: date) }
    public func timeStr(_ date: Date) -> String { dfClock.string(from: date) }

    public func baseDirectory() -> URL { StoragePaths.baseDirectory() }

    public func relativePath(for url: URL) -> String { StoragePaths.relativePath(for: url) }

    public func resolveRelativePath(_ path: String) -> URL { StoragePaths.resolveRelativePath(path) }

    public func recordingsDirectory() -> URL { baseDirectory().appendingPathComponent("Recordings", isDirectory: true) }
    public func audioDirectory() -> URL { recordingsDirectory() }
    public func trashDirectory() -> URL { baseDirectory().appendingPathComponent("Trash", isDirectory: true) }
    public func temporaryDirectory() -> URL { URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true) }
    
    public func legacyBaseDirectory() -> URL {
        if StoragePaths.isTestProcess || ProcessInfo.processInfo.environment["WIMM_BASE_DIR"] != nil {
            return baseDirectory().appendingPathComponent("Legacy", isDirectory: true)
        }
        #if os(macOS)
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Wimm", isDirectory: true)
        #else
        return baseDirectory()
        #endif
    }
    
    public func legacyRecordingsDirectory() -> URL { legacyBaseDirectory().appendingPathComponent("Recordings", isDirectory: true) }

    public func ensureDirectoryExists() throws {
        // Create recordings and trash directories
        try FileManager.default.createDirectory(at: recordingsDirectory(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trashDirectory(), withIntermediateDirectories: true)
    }

    public let supportedDocumentExtensions: Set<String> =
        AttachmentTypeHelper.pdfExtensions
        .union(AttachmentTypeHelper.imageExtensions)
        .union(AttachmentTypeHelper.textExtensions)
        .union(AttachmentTypeHelper.officeExtensions)
    public let supportedAudioExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "aac", "opus", "oga", "ogg"]

    public func isAudioFile(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }
    
    public func isAttachmentFile(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        return base.contains("_Attach_")
    }

    /// `_mini`/`_micro` are generated derived-audio tiers (see `miniURL`/`microURL`), never
    /// primary content. Every recordings/trash/sync listing must exclude them so they don't
    /// surface as phantom notes — use this instead of ad-hoc suffix checks.
    public func isDerivedAudioFile(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        return base.hasSuffix("_mini") || base.hasSuffix("_micro")
    }

    /// Preview-image shapes written next to a capture: `{base}.heic`/`{base}.png`
    /// (PDF first page, legacy screenshot) and `{base}_screenN.heic` (HUD screen grabs).
    ///
    /// These are renders *of* another file in the session, so a listing that groups files
    /// by session base must never anchor a note on one while a primary file is present —
    /// a PDF whose first page was rendered would otherwise surface as an image note.
    /// A standalone imported image *is* its own note, so this is a ranking signal, not a
    /// filter: callers fall back to the preview when it is the only file in the group.
    public func isDerivedPreviewImage(_ url: URL, sessionBase base: String) -> Bool {
        previewImageSessionBase(url) == base
    }

    /// The session base a preview-shaped image would belong to, or nil when the file is
    /// not preview-shaped. Says nothing about whether that session has a primary file —
    /// see `isDerivedPreviewImage(_:sessionBase:)`.
    public func previewImageSessionBase(_ url: URL) -> String? {
        guard ["heic", "png"].contains(url.pathExtension.lowercased()) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: "_screen", options: .backwards) {
            let index = name[range.upperBound...]
            if !index.isEmpty, index.allSatisfy(\.isNumber) {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }

    /// Strips trailing `_mini`/`_micro` derived-audio suffixes, if present, to recover the
    /// session base name those files were generated from. Loops so cascaded junk from the
    /// derive-from-derived bug ("..._micro_mini") still resolves to the true base.
    public func strippingDerivedAudioSuffix(_ base: String) -> String {
        var base = base
        while true {
            if base.hasSuffix("_mini") { base = String(base.dropLast(5)); continue }
            if base.hasSuffix("_micro") { base = String(base.dropLast(6)); continue }
            return base
        }
    }
    
    public func parentSessionID(forAttachment url: URL) -> String? {
        let base = url.deletingPathExtension().lastPathComponent
        guard let range = base.range(of: "_Attach_") else { return nil }
        return String(base[..<range.lowerBound])
    }

    public func isDocumentFile(_ url: URL) -> Bool {
        supportedDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    public func isSupportedRecordingFile(_ url: URL) -> Bool {
        isAudioFile(url) || isDocumentFile(url)
    }

    /// Returns an available URL for a newly allocated identity. In the
    /// extraordinarily unlikely event of a short-ID collision in the same
    /// minute, the visible ID expands deterministically.
    public func newRecordingURL(
        identity: RecordingIdentity,
        extension: String = "m4a",
        in directory: URL? = nil
    ) -> URL {
        let directory = directory ?? recordingsDirectory()
        for length in [8, 12, 32] {
            let candidate = directory.appendingPathComponent(
                identity.fileName(extension: `extension`, idLength: length)
            )
            let metadata = metadataURL(forRecordingURL: candidate)
            if !FileManager.default.fileExists(atPath: candidate.path),
               !FileManager.default.fileExists(atPath: metadata.path) {
                return candidate
            }
        }

        let base = identity.fileName(extension: "", idLength: 32)
        var index = 2
        while true {
            let candidate = directory
                .appendingPathComponent("\(base)_\(index)")
                .appendingPathExtension(`extension`)
            if !FileManager.default.fileExists(atPath: candidate.path),
               !FileManager.default.fileExists(atPath: metadataURL(forRecordingURL: candidate).path) {
                return candidate
            }
            index += 1
        }
    }

    /// Three name shapes are live on disk and all of them must keep parsing:
    /// second-precision (the format `RecordingIdentity` writes, and what the
    /// oldest captures used), the minute-truncated variant written between
    /// 2026-07-27 and 2026-07-31, and the `Wimm_Stream_` segments.
    public func recordingDateFromFileName(_ url: URL) -> Date? {
        let base = url.deletingPathExtension().lastPathComponent
        if base.hasPrefix("Wimm_") {
            let rawStamp = String(base.dropFirst("Wimm_".count))
            let stamp = String(rawStamp.prefix(19))
            if let date = dfFileName.date(from: stamp) {
                return date
            }
            return dfMinuteFileName.date(from: String(rawStamp.prefix(16)))
        }
        if base.hasPrefix("Wimm_Stream_") {
            let suffix = base.dropFirst("Wimm_Stream_".count)
            let stamp = String(suffix.prefix(15))
            return dfStreamFileName.date(from: stamp)
        }
        return nil
    }

    public func screenshotURL(forRecordingURL recording: URL) -> URL {
        let base = recording.deletingPathExtension().lastPathComponent
        return recording.deletingLastPathComponent().appendingPathComponent("\(base).heic")
    }
    
    public func allScreenshotURLs(forRecordingURL recording: URL) -> [URL] {
        screenshotURLs(for: recording, exists: { FileManager.default.fileExists(atPath: $0.path) }) {
            let dir = recording.deletingLastPathComponent()
            let prefix = recording.deletingPathExtension().lastPathComponent + "_Attach_screenshot_"
            return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension.lowercased() == "heic" }
        }
    }

    /// Reuse attachment screenshot names grouped by a batch directory listing.
    /// Named main/screens still use fileExists, preserving case-insensitive
    /// filesystems and broken-symlink behavior without enumerating the directory.
    public func allScreenshotURLs(
        forRecordingURL recording: URL,
        attachmentScreenshotFilenames: [String]
    ) -> [URL] {
        screenshotURLs(for: recording, exists: { FileManager.default.fileExists(atPath: $0.path) }) {
            attachmentScreenshotFilenames.map { recording.deletingLastPathComponent().appendingPathComponent($0) }
        }
    }

    private func screenshotURLs(for recording: URL, exists: (URL) -> Bool, attachments: () -> [URL]) -> [URL] {
        let base = recording.deletingPathExtension().lastPathComponent
        let dir = recording.deletingLastPathComponent()
        var urls: [URL] = []
        let mainURL = dir.appendingPathComponent("\(base).heic")
        if exists(mainURL) { urls.append(mainURL) }
        for i in 1...10 {
            let screenURL = dir.appendingPathComponent("\(base)_screen\(i).heic")
            guard exists(screenURL) else { break }
            urls.append(screenURL)
        }
        if urls.isEmpty {
            urls = attachments().sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return urls
    }

    public func legacyPNGScreenshotURL(forRecordingURL recording: URL) -> URL {
        let base = recording.deletingPathExtension().lastPathComponent
        return recording.deletingLastPathComponent().appendingPathComponent("\(base).png")
    }
    
    public func metadataURL(forRecordingURL recording: URL) -> URL {
        var base = recording.deletingPathExtension().lastPathComponent
        if let range = base.range(of: "_Attach_") {
            base = String(base[..<range.lowerBound])
        }
        let dir = recording.deletingLastPathComponent()
        let newURL = dir.appendingPathComponent("\(base).meta.json")
        let legacyURL = dir.appendingPathComponent("\(base).metadata.json")
        
        if FileManager.default.fileExists(atPath: newURL.path) {
            return newURL
        }
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            return legacyURL
        }
        return newURL
    }
    
    public func miniURL(forRecordingURL recording: URL) -> URL {
        let base = recording.deletingPathExtension().lastPathComponent + "_mini"
        return recording.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("m4a")
    }

    /// Smallest derived copy: a silence-trimmed `_micro.m4a` used for transcription
    /// upload so the cloud transcriber is billed for fewer audio seconds.
    public func microURL(forRecordingURL recording: URL) -> URL {
        let base = recording.deletingPathExtension().lastPathComponent + "_micro"
        return recording.deletingLastPathComponent().appendingPathComponent(base).appendingPathExtension("m4a")
    }

    public func fileCreationDate(_ url: URL) throws -> Date {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.creationDate] as? Date) ?? Date()
    }
    
    public func fileModificationDate(_ url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? (try? fileCreationDate(url)) ?? Date()
    }

    /// Best-effort attempt to apply file timestamps. Some platforms/filesystems may reject setting `.creationDate`.
    @discardableResult
    public func trySetFileDates(_ url: URL, created: Date?, modified: Date?) -> Bool {
        var attrs: [FileAttributeKey: Any] = [:]
        if let created { attrs[.creationDate] = created }
        if let modified { attrs[.modificationDate] = modified }
        guard !attrs.isEmpty else { return true }

        do {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: url.path)
            return true
        } catch {
            // Retry without creationDate (e.g. iOS or some FS might reject it).
            if created != nil, modified != nil {
                do {
                    try FileManager.default.setAttributes([.modificationDate: modified as Any], ofItemAtPath: url.path)
                    return true
                } catch {
                    return false
                }
            }
            return false
        }
    }

    public func attachmentFileNameForClipboardText(
        sessionID: String,
        strategy: FileStore.AttachmentNamingStrategy,
        uniqueSuffix: String
    ) -> String {
        let suffix = strategy == .timestamp
            ? "Attach_\(uniqueSuffix)"
            : "Attach_\(UUID().uuidString)"
        return "\(sessionID)_\(suffix)_Text.txt"
    }

}

// MARK: - Legacy Compatibility

public enum FileStore {
    public enum AttachmentNamingStrategy {
        case timestamp
        case uniqueUUID
    }
    
    public static func baseDirectory() -> URL { DefaultFileStore.shared.baseDirectory() }
    public static func recordingsDirectory() -> URL { DefaultFileStore.shared.recordingsDirectory() }
    public static func audioDirectory() -> URL { DefaultFileStore.shared.audioDirectory() }
    public static func trashDirectory() -> URL { DefaultFileStore.shared.trashDirectory() }
    public static func temporaryDirectory() -> URL { DefaultFileStore.shared.temporaryDirectory() }
    public static func legacyBaseDirectory() -> URL { DefaultFileStore.shared.legacyBaseDirectory() }
    public static func legacyRecordingsDirectory() -> URL { DefaultFileStore.shared.legacyRecordingsDirectory() }

    public static func ensureDirectoryExists() throws { try DefaultFileStore.shared.ensureDirectoryExists() }
    
    // Properties are a bit annoying to proxy directly if they are computed
    public static var supportedDocumentExtensions: Set<String> { DefaultFileStore.shared.supportedDocumentExtensions }
    public static var supportedAudioExtensions: Set<String> { DefaultFileStore.shared.supportedAudioExtensions }

    public static func isAudioFile(_ url: URL) -> Bool { DefaultFileStore.shared.isAudioFile(url) }
    public static func isAttachmentFile(_ url: URL) -> Bool { DefaultFileStore.shared.isAttachmentFile(url) }
    public static func parentSessionID(forAttachment url: URL) -> String? { DefaultFileStore.shared.parentSessionID(forAttachment: url) }
    public static func isDocumentFile(_ url: URL) -> Bool { DefaultFileStore.shared.isDocumentFile(url) }
    public static func isSupportedRecordingFile(_ url: URL) -> Bool { DefaultFileStore.shared.isSupportedRecordingFile(url) }
    public static func isDerivedAudioFile(_ url: URL) -> Bool { DefaultFileStore.shared.isDerivedAudioFile(url) }
    public static func isDerivedPreviewImage(_ url: URL, sessionBase base: String) -> Bool {
        DefaultFileStore.shared.isDerivedPreviewImage(url, sessionBase: base)
    }
    public static func previewImageSessionBase(_ url: URL) -> String? {
        DefaultFileStore.shared.previewImageSessionBase(url)
    }
    public static func strippingDerivedAudioSuffix(_ base: String) -> String { DefaultFileStore.shared.strippingDerivedAudioSuffix(base) }

    public static func relativePath(for url: URL) -> String { DefaultFileStore.shared.relativePath(for: url) }
    public static func resolveRelativePath(_ path: String) -> URL { DefaultFileStore.shared.resolveRelativePath(path) }

    public static func newRecordingURL(
        identity: RecordingIdentity,
        extension: String = "m4a",
        in directory: URL? = nil
    ) -> URL {
        DefaultFileStore.shared.newRecordingURL(
            identity: identity,
            extension: `extension`,
            in: directory
        )
    }
    public static func recordingDateFromFileName(_ url: URL) -> Date? { DefaultFileStore.shared.recordingDateFromFileName(url) }

    public static func screenshotURL(forRecordingURL recording: URL) -> URL { DefaultFileStore.shared.screenshotURL(forRecordingURL: recording) }
    public static func allScreenshotURLs(forRecordingURL recording: URL) -> [URL] { DefaultFileStore.shared.allScreenshotURLs(forRecordingURL: recording) }
    public static func allScreenshotURLs(forRecordingURL recording: URL, attachmentScreenshotFilenames: [String]) -> [URL] {
        DefaultFileStore.shared.allScreenshotURLs(forRecordingURL: recording, attachmentScreenshotFilenames: attachmentScreenshotFilenames)
    }
    public static func legacyPNGScreenshotURL(forRecordingURL recording: URL) -> URL { DefaultFileStore.shared.legacyPNGScreenshotURL(forRecordingURL: recording) }
    public static func metadataURL(forRecordingURL recording: URL) -> URL { DefaultFileStore.shared.metadataURL(forRecordingURL: recording) }
    public static func miniURL(forRecordingURL recording: URL) -> URL { DefaultFileStore.shared.miniURL(forRecordingURL: recording) }
    public static func microURL(forRecordingURL recording: URL) -> URL { DefaultFileStore.shared.microURL(forRecordingURL: recording) }

    public static func fullDateTime(_ date: Date) -> String { DefaultFileStore.shared.fullDateTime(date) }
    public static func timeStr(_ date: Date) -> String { DefaultFileStore.shared.timeStr(date) }

    public static func append(text: String, to url: URL) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: url)
        }
    }

    public static func fileCreationDate(_ url: URL) throws -> Date { try DefaultFileStore.shared.fileCreationDate(url) }
    public static func fileModificationDate(_ url: URL) -> Date { DefaultFileStore.shared.fileModificationDate(url) }
    @discardableResult
    public static func trySetFileDates(_ url: URL, created: Date?, modified: Date?) -> Bool {
        DefaultFileStore.shared.trySetFileDates(url, created: created, modified: modified)
    }

    public static func attachmentFileNameForClipboardText(
        sessionID: String,
        strategy: AttachmentNamingStrategy,
        uniqueSuffix: String
    ) -> String {
        DefaultFileStore.shared.attachmentFileNameForClipboardText(sessionID: sessionID, strategy: strategy, uniqueSuffix: uniqueSuffix)
    }

}

// MARK: - Metadata sidecar helpers

/// Serializes in-process read-modify-write operations on adjacent metadata
/// sidecars. This intentionally does not claim to coordinate with another
/// process (for example a simultaneously running `wimm-cli`).
private let metadataSidecarMutationLock = NSLock()

extension FileStore {
    public static func listAllRecordingFiles() -> [URL] {
        let dir = baseDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.filter { $0.pathExtension == "m4a" }
    }

    public static func upsertMetadata(for recordingURL: URL, updates: [String: Any]) {
        let sanitizedUpdates = FileStore.sanitizeMetaJSONUpdates(updates)
        guard !sanitizedUpdates.isEmpty else { return }
        mutateMetadata(for: recordingURL) { current in
            for (key, value) in sanitizedUpdates {
                current[key] = value
            }
            return true
        }
    }

    /// The one read-modify-write door for a `.meta.json` sidecar at an explicit
    /// path. Every writer of a sidecar goes through here.
    ///
    /// A sidecar is shared: the recorder writes `recordingId`, `NoteOrigin`
    /// writes `origin`, CloudSync writes `syncId`, transcription writes
    /// `transcription`, analysis writes `noteCard`, the trash writes its
    /// markers — often within the same second of one recording. Each of those
    /// used to do its own read-modify-write, and only `upsertMetadata` took the
    /// lock, so the lock serialized one writer against itself and nobody else.
    /// Two unsynchronized read-modify-writes of one file lose whichever update
    /// lands first.
    ///
    /// Return `true` from `mutation` when the dictionary should be written.
    /// The dictionary is validated before serializing — `JSONSerialization`
    /// raises an Objective-C exception, not a Swift error, on a non-JSON
    /// value, which would crash rather than throw. Do not call another sidecar
    /// writer from inside `mutation`: the lock is not recursive.
    ///
    /// In-process only; it does not coordinate with a concurrently running
    /// `wimm-cli`.
    public static let sidecarDidChange = Notification.Name("Wimm.sidecarDidChange")

    public static func mutateSidecar(
        at sidecarURL: URL,
        _ mutation: (inout [String: Any]) throws -> Bool
    ) throws {
        var didWrite = false
        metadataSidecarMutationLock.lock()
        defer {
            metadataSidecarMutationLock.unlock()
            if didWrite { NotificationCenter.default.post(name: sidecarDidChange, object: sidecarURL) }
        }

        // Only a missing or empty file starts from nothing; an unreadable one
        // throws, or the write below would replace everything it held.
        var current: [String: Any] = [:]
        let existing: Data
        do {
            existing = try Data(contentsOf: sidecarURL)
        } catch CocoaError.fileReadNoSuchFile {
            existing = Data()
        }
        if !existing.isEmpty {
            guard let json = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: sidecarURL.path])
            }
            current = json
        }

        guard try mutation(&current) else { return }
        guard JSONSerialization.isValidJSONObject(current) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        let data = try JSONSerialization.data(
            withJSONObject: current,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: sidecarURL, options: .atomic)
        didWrite = true
    }

    /// `mutateSidecar` for a recording, resolving its sidecar path, with errors
    /// swallowed — the historical contract of the metadata helpers here.
    private static func mutateMetadata(
        for recordingURL: URL,
        _ mutation: (inout [String: Any]) -> Bool
    ) {
        try? mutateSidecar(at: metadataURL(forRecordingURL: recordingURL), mutation)
    }

    /// The single in-process mutation door for the nested `transcription`
    /// dictionary. Optional top-level removals happen in the same sidecar
    /// read-modify-write, which lets a successful run clear failure markers
    /// without a second disk round-trip.
    public static func mutateTranscription(
        for recordingURL: URL,
        removingMetadataKeys keys: Set<String> = [],
        _ mutation: (inout [String: Any]) -> Bool
    ) {
        mutateMetadata(for: recordingURL) { metadata in
            var transcription = transcriptionDictionary(from: metadata["transcription"]) ?? [:]
            guard mutation(&transcription) else { return false }
            metadata["transcription"] = transcription
            for key in keys {
                metadata.removeValue(forKey: key)
            }
            return true
        }
    }

    /// The sidecar's `transcription` value as a dictionary. The iPhone recorder
    /// (`RecordingMetadata`) writes it as a plain string — the live on-device
    /// text. Read as a dictionary, that string is both the transcript and the
    /// realtime text (`localTranscript`), so the first file run that replaces
    /// the transcript no longer throws the live text away.
    public static func transcriptionDictionary(from value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return ["transcript": text, "localTranscript": text,
                "speechStatus": TranscriptionSpeechStatus.speech.rawValue]
    }

    /// Merges fields into the nested `transcription` dictionary.
    /// `upsertMetadata` replaces top-level keys wholesale, so writing
    /// `transcription` directly would drop whatever the transcription pass
    /// already stored (transcript, provider, timings).
    public static func upsertTranscriptionFields(for recordingURL: URL, updates: [String: Any]) {
        let sanitizedUpdates = FileStore.sanitizeMetaJSONUpdates(updates)
        guard !sanitizedUpdates.isEmpty else { return }
        mutateTranscription(for: recordingURL) { transcription in
            for (key, value) in sanitizedUpdates {
                transcription[key] = value
            }
            return true
        }
    }

}
