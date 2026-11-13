import Foundation
import WimmDomain

/// Watches the Apple Voice Memos iCloud library and reports recordings that
/// have not been imported into the Wimm library yet.
///
/// Import state is persisted as JSON next to the rest of the app data, keyed
/// by the source file name (unique inside the Voice Memos folder). A memo is
/// imported once; later edits/trims of the same memo are intentionally
/// ignored to avoid duplicate notes.
public actor VoiceMemosAutoImporter {

    public struct ScanResult: Sendable {
        public let pending: [URL]
        public let accessDenied: Bool

        public init(pending: [URL], accessDenied: Bool) {
            self.pending = pending
            self.accessDenied = accessDenied
        }
    }

    private struct State: Codable {
        var imported: [String: Entry] = [:]
        var backfillCompleted: Bool = false

        struct Entry: Codable {
            var importedAt: Date
            var size: Int64?
            var destinationPath: String?
        }
    }

    /// Minimum time since last modification before a file is considered
    /// fully synced and safe to copy.
    public static let defaultMinimumAge: TimeInterval = 60

    private let folder: URL?
    private let stateURL: URL
    private let recordingsDirectory: URL
    private var state: State?

    public init(
        folder: URL? = VoiceMemosAutoImporter.defaultFolder(),
        stateURL: URL = VoiceMemosAutoImporter.defaultStateURL(),
        recordingsDirectory: URL = FileStore.recordingsDirectory()
    ) {
        self.folder = folder
        self.stateURL = stateURL
        self.recordingsDirectory = recordingsDirectory
    }

    /// The Voice Memos recordings folder on this Mac, if present.
    ///
    /// A TCC-protected folder reports "unreachable" with a permission error
    /// even though it exists — treat that as present so the scan can surface
    /// `accessDenied` (and trigger the system prompt) instead of silently
    /// disabling the feature.
    public static func defaultFolder() -> URL? {
        #if !os(macOS)
        // The Voice Memos iCloud library folder only exists on macOS.
        return nil
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"),
            home.appendingPathComponent("Library/Application Support/com.apple.voicememos/Recordings")
        ]
        return candidates.first { candidate in
            do {
                return try candidate.checkResourceIsReachable()
            } catch {
                let nsError = error as NSError
                return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
            }
        }
        #endif
    }

    public static func defaultStateURL() -> URL {
        StoragePaths.baseDirectory().appendingPathComponent("voicememos_import_state.json")
    }

    /// Lists memos that are stable (older than `minimumAge`) and not yet imported.
    public func pendingFiles(
        now: Date = Date(),
        minimumAge: TimeInterval = VoiceMemosAutoImporter.defaultMinimumAge
    ) -> ScanResult {
        guard let folder else { return ScanResult(pending: [], accessDenied: false) }
        loadStateIfNeeded()

        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // TCC denial surfaces as NSFileReadNoPermissionError / EPERM.
            let nsError = error as NSError
            let denied = nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError
            return ScanResult(pending: [], accessDenied: denied)
        }

        var pending: [(url: URL, modified: Date)] = []
        for url in contents {
            guard url.pathExtension.lowercased() == "m4a" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            if values?.isDirectory == true { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) >= minimumAge else { continue }
            if state?.imported[url.lastPathComponent] != nil { continue }
            pending.append((url, modified))
        }
        pending.sort { $0.modified < $1.modified }
        return ScanResult(pending: pending.map(\.url), accessDenied: false)
    }

    /// Records the given source memos as imported so they are skipped on the
    /// next scan. `destinations` is a parallel best-effort mapping by source path.
    public func markImported(sources: [URL], destinations: [String: String] = [:]) {
        guard !sources.isEmpty else { return }
        loadStateIfNeeded()
        let now = Date()
        for source in sources {
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            state?.imported[source.lastPathComponent] = State.Entry(
                importedAt: now,
                size: size.map(Int64.init),
                destinationPath: destinations[source.path]
            )
        }
        saveState()
    }

    /// One-time pass over existing library metadata: memos that were imported
    /// manually (via the open-panel flow) carry `sourcePath` pointing into the
    /// Voice Memos folder and must not be imported again.
    public func backfillFromExistingMetadataIfNeeded() {
        guard let folder else { return }
        loadStateIfNeeded()
        guard state?.backfillCompleted != true else { return }

        let fm = FileManager.default
        let metaFiles = (try? fm.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasSuffix(".meta.json") || $0.lastPathComponent.hasSuffix(".metadata.json") } ?? []

        let folderPath = folder.standardizedFileURL.path
        let now = Date()
        for metaURL in metaFiles {
            guard
                let data = try? Data(contentsOf: metaURL),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let sourcePath = json[MetadataKey.sourcePath.rawValue] as? String,
                sourcePath.hasPrefix(folderPath)
            else { continue }
            let sourceName = (sourcePath as NSString).lastPathComponent
            if state?.imported[sourceName] == nil {
                state?.imported[sourceName] = State.Entry(importedAt: now, size: nil, destinationPath: nil)
            }
        }
        state?.backfillCompleted = true
        saveState()
    }

    // MARK: - State persistence

    private func loadStateIfNeeded() {
        guard state == nil else { return }
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data) {
            state = decoded
        } else {
            state = State()
        }
    }

    private func saveState() {
        guard let state else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: stateURL, options: .atomic)
    }
}
