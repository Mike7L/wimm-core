import Foundation
import WimmDomain

/// One-shot snapshot of recording directory contents, built with a single
/// `contentsOfDirectory` per directory. Lets batch note building (journal
/// rebuild over thousands of notes) resolve screenshot/sidecar existence via
/// O(1) set lookups instead of per-note `fileExists`/directory scans.
public struct RecordingsDirectoryIndex: Sendable {
    private struct DirectoryEntry: Sendable {
        let filenames: Set<String>
        /// Session base name → first (lexicographically) HUD attach-screenshot
        /// filename ("{base}_Attach_screenshot_{UUID}.heic").
        let firstAttachScreenshotByBase: [String: String]
        let attachmentsByBase: [String: [String]]
        let screenshotAttachmentsByBase: [String: [String]]
    }

    private let entries: [String: DirectoryEntry]

    public init(directories: [URL]) {
        var listings: [URL: [String]] = [:]
        for dir in directories {
            let standardized = dir.standardizedFileURL
            guard listings[standardized] == nil,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            listings[standardized] = names
        }
        self.init(directoryFilenames: listings)
    }

    /// Reuse a listing already acquired by the batch owner.
    public init(directoryFilenames: [URL: [String]]) {
        var entries: [String: DirectoryEntry] = [:]
        for (dir, names) in directoryFilenames {
            let standardizedPath = dir.standardizedFileURL.path
            guard entries[standardizedPath] == nil else { continue }
            var attachmentsByBase: [String: [String]] = [:]
            var screenshotsByBase: [String: [String]] = [:]
            for name in names {
                guard let range = name.range(of: "_Attach_") else { continue }
                let base = String(name[..<range.lowerBound])
                attachmentsByBase[base, default: []].append(name)
                if name.hasPrefix(base + "_Attach_screenshot_"), name.lowercased().hasSuffix(".heic") {
                    screenshotsByBase[base, default: []].append(name)
                }
            }

            var attachByBase: [String: String] = [:]
            for name in names where name.lowercased().hasSuffix(".heic") {
                guard let range = name.range(of: "_Attach_screenshot_") else { continue }
                let base = String(name[..<range.lowerBound])
                if let existing = attachByBase[base] {
                    if name < existing { attachByBase[base] = name }
                } else {
                    attachByBase[base] = name
                }
            }
            entries[standardizedPath] = DirectoryEntry(
                filenames: Set(names),
                firstAttachScreenshotByBase: attachByBase,
                attachmentsByBase: attachmentsByBase,
                screenshotAttachmentsByBase: screenshotsByBase
            )
        }
        self.entries = entries
    }

    public func fileURLs(in directory: URL) -> [URL]? {
        entries[directory.standardizedFileURL.path]?.filenames.map { directory.appendingPathComponent($0) }
    }

    public func attachmentURLs(forRecordingURL recording: URL) -> [URL] {
        let dir = recording.deletingLastPathComponent()
        let base = recording.deletingPathExtension().lastPathComponent
        return (entries[dir.standardizedFileURL.path]?.attachmentsByBase[base] ?? [])
            .map { dir.appendingPathComponent($0) }
    }

    public func allScreenshotURLs(forRecordingURL recording: URL) -> [URL] {
        let dir = recording.deletingLastPathComponent()
        guard let entry = entries[dir.standardizedFileURL.path] else { return [] }
        let base = recording.deletingPathExtension().lastPathComponent
        return FileStore.allScreenshotURLs(
            forRecordingURL: recording,
            attachmentScreenshotFilenames: entry.screenshotAttachmentsByBase[base] ?? []
        )
    }

    /// Whether the index covers the directory containing `url`.
    public func covers(directoryOf url: URL) -> Bool {
        entries[url.deletingLastPathComponent().standardizedFileURL.path] != nil
    }

    public func contains(_ url: URL) -> Bool {
        entries[url.deletingLastPathComponent().standardizedFileURL.path]?
            .filenames.contains(url.lastPathComponent) ?? false
    }

    /// Mirrors `FileStore.allScreenshotURLs(forRecordingURL:).first` semantics:
    /// main "{base}.heic", else "{base}_screen1.heic", else the first sorted
    /// HUD attach screenshot — without touching the filesystem.
    public func firstScreenshotURL(forRecordingURL recording: URL) -> URL? {
        let dir = recording.deletingLastPathComponent()
        guard let entry = entries[dir.standardizedFileURL.path] else { return nil }
        let base = recording.deletingPathExtension().lastPathComponent

        let main = "\(base).heic"
        if entry.filenames.contains(main) { return dir.appendingPathComponent(main) }

        let firstScreen = "\(base)_screen1.heic"
        if entry.filenames.contains(firstScreen) { return dir.appendingPathComponent(firstScreen) }

        if let attach = entry.firstAttachScreenshotByBase[base] {
            return dir.appendingPathComponent(attach)
        }
        return nil
    }
}
