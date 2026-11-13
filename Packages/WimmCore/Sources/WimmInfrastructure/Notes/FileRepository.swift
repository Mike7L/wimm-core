import Foundation
import WimmDomain

/// Handles file listing and basic file operations for recordings.
public actor FileRepository: FileRepositoryProtocol {
    public enum Order: Sendable { case ascending, descending }

    public struct FileAssets: Sendable {
        public let screenshotURL: URL?
        public let metadataURL: URL?

        public init(screenshotURL: URL?, metadataURL: URL?) {
            self.screenshotURL = screenshotURL
            self.metadataURL = metadataURL
        }
    }

    private let fileManager = FileManager.default

    public init() {}

    // MARK: - Recordings Listing
    
    /// Cache for recordings list to avoid repeated filesystem scans
    private var cachedRecordings: [URL]?
    private var cacheTimestamp: Date?
    private let cacheValidityDuration: TimeInterval = 1.0  // 1 second cache

    public func recordings(order: Order = .ascending, limit: Int? = nil) -> [URL] {
        var list = listRecordingsAscending()
        if order == .descending { list = Array(list.reversed()) }
        if let limit, limit < list.count { return Array(list.prefix(limit)) }
        return list
    }

    /// Thread-safe implementation of recordings listing (moved from FileStore for concurrency safety)
    private func listRecordingsAscending() -> [URL] {
        // Check cache validity
        if let cached = cachedRecordings,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheValidityDuration {
            return cached
        }
        
        let fm = fileManager
        let primaryDir = FileStore.recordingsDirectory()
        let legacyDir = FileStore.legacyRecordingsDirectory()

        func list(_ dir: URL) -> [URL] {
            (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }

        // Fetch from new location; ensure we include legacy only if it exists
        var all: [URL] = []
        let primary = list(primaryDir)
        all.append(contentsOf: primary)

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: legacyDir.path, isDirectory: &isDir), isDir.boolValue {
            let legacy = list(legacyDir)
            all.append(contentsOf: legacy)
        }

        // Filter to supported files: audio (skip generated _mini/_micro) and documents (e.g. .pdf)
        all = all.filter { url in
            let ext = url.pathExtension.lowercased()
            if FileStore.supportedAudioExtensions.contains(ext) {
                return !FileStore.isDerivedAudioFile(url)
            }
            return FileStore.supportedDocumentExtensions.contains(ext)
        }

        // Deduplicate by filename, preferring the new location when conflicts exist
        var byName: [String: URL] = [:]
        for url in all {
            let name = url.lastPathComponent
            if byName[name] == nil { byName[name] = url }
        }
        // If an item exists in both, override with primary version
        for url in primary {
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if FileStore.supportedAudioExtensions.contains(ext) && !FileStore.isDerivedAudioFile(url) {
                byName[name] = url
            } else if FileStore.supportedDocumentExtensions.contains(ext) {
                byName[name] = url
            }
        }

        let unique = Array(byName.values)
        // Sort by filename ascending — Wimm_YYYY-MM-DD_HH-mm-ss embeds date in name.
        // Pure string compare, no stat syscalls.
        let sorted = unique.sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        // ATOMIC GROUPING: 
        // We group all files by their "Session ID" (base name).
        // 1. Identify the Session ID from the filename.
        //    Rules:
        //    - Standard: "Wimm_2024-01-21_12-00-00.m4a" -> "Wimm_2024-01-21_12-00-00"
        //    - Attachment: "Wimm_2024-01-21_12-00-00_Attach_0.png" -> "Wimm_2024-01-21_12-00-00"
        //    - Screenshot: "Wimm_2024-01-21_12-00-00_screen1.heic" -> "Wimm_2024-01-21_12-00-00"
        //    - Legacy: "Wimm_2024-01-21_12-00-00_mini.m4a" -> "Wimm_2024-01-21_12-00-00"
        //    - Derived: "Wimm_2024-01-21_12-00-00_micro.m4a" -> "Wimm_2024-01-21_12-00-00"
        
        var groups: [String: [URL]] = [:]
        for url in sorted {
            let base = canonicalSessionID(for: url)
            groups[base, default: []].append(url)
        }
        
        // For each group, pick the "Anchor" file.
        // Priority:
        // 1. .m4a (Primary Audio)
        // 2. Any file that is not a derived preview image — an imported PDF sorts after
        //    its rendered "{base}.heic" first page, so preferring the preview would show
        //    the document as an image note.
        // 3. Any other file (First one, if no audio exists)

        var result: [URL] = []
        
        // We iterate the original sorted list to maintain creation time order roughly.
        // We keep track of processed Session IDs.
        var processedSessions = Set<String>()
        
        for url in sorted {
            let base = canonicalSessionID(for: url)
            
            if processedSessions.contains(base) { continue }
            
            // This is a new session we haven't emitted yet.
            // Find the best anchor in the group.
            if let group = groups[base] {
                // Determine Anchor
                if let audio = group.first(where: { url in
                    url.pathExtension.lowercased() == "m4a" && !FileStore.isDerivedAudioFile(url)
                }) {
                    result.append(audio)
                } else if let primary = group.first(where: { url in
                    !FileStore.isDerivedPreviewImage(url, sessionBase: base)
                }) {
                    result.append(primary)
                } else if let first = group.first {
                    // Fallback anchor: the session really is just an image
                    // (standalone .heic/.png import) or only attachments.
                    result.append(first)
                }
                processedSessions.insert(base)
            }
        }
        
        // Update cache
        cachedRecordings = result
        cacheTimestamp = Date()
        
        return result
    }

    private func canonicalSessionID(for url: URL) -> String {
        var base = url.deletingPathExtension().lastPathComponent

        if let range = base.range(of: "_Attach_") {
            base = String(base[..<range.lowerBound])
        } else if let range = base.range(of: "_paste_") {
            // Clipboard text files should belong to the parent session, not become standalone notes.
            base = String(base[..<range.lowerBound])
        } else if let range = base.range(of: "_screen", options: .backwards) {
            let suffix = base[range.upperBound...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                base = String(base[..<range.lowerBound])
            }
        } else {
            base = FileStore.strippingDerivedAudioSuffix(base)
        }

        return base
    }
    
    /// Invalidate the recordings cache (call after file operations)
    public func invalidateCache() {
        cachedRecordings = nil
        cacheTimestamp = nil
    }

    // MARK: - Assets

    public func assets(for file: URL) -> FileAssets {
        let base = file.deletingPathExtension()
        var screenshot: URL?
        
        // Priority check for supported screenshot formats
        // First check for main screenshot, then multi-screen variants
        let allScreenshots = FileStore.allScreenshotURLs(forRecordingURL: file)
        screenshot = allScreenshots.first
        
        // Legacy fallback: check for PNG screenshots
        if screenshot == nil {
            let extensions = ["png", "jpg", "jpeg"]
            for ext in extensions {
                let candidate = base.appendingPathExtension(ext)
                if fileManager.fileExists(atPath: candidate.path) {
                    screenshot = candidate
                    break
                }
            }
        }

        let meta = FileStore.metadataURL(forRecordingURL: file)
        let metadataURL = fileManager.fileExists(atPath: meta.path) ? meta : nil
        return FileAssets(screenshotURL: screenshot, metadataURL: metadataURL)
    }

}
