import Foundation

/// Short-lived, batch-owned directory listings. A directory's mtime/identity is
/// checked on every use (including after collection); additions/removals refresh
/// the grouping. File contents and sidecar attachment lists are never cached.
public final class RecordingBundleDirectorySnapshot: @unchecked Sendable {
    private struct Version: Equatable {
        let modified: Date
        let inode: UInt64
    }
    private struct Entry {
        let version: Version
        let index: RecordingsDirectoryIndex
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var enumerationCount = 0

    public init() {}

    // Internal diagnostics let tests count actual listings, without filesystem tracing.
    var directoryEnumerationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return enumerationCount
    }

    func fileURLs(in directory: URL) throws -> [URL] {
        try withCurrentIndex(in: directory) { $0.fileURLs(in: directory) ?? [] }
    }

    func withCurrentIndex<T>(in directory: URL, _ body: (RecordingsDirectoryIndex) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let key = directory.standardizedFileURL.path
        // A changing directory must not produce an incomplete successful upload.
        // Bound retries under constant churn; the normal sync retry will try again.
        for _ in 0..<3 {
            let before = try version(of: directory)
            let index: RecordingsDirectoryIndex
            if let entry = entries[key], entry.version == before {
                index = entry.index
            } else {
                enumerationCount += 1
                let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                index = RecordingsDirectoryIndex(directoryFilenames: [directory: names])
                guard try version(of: directory) == before else { continue }
                entries[key] = Entry(version: before, index: index)
            }
            do {
                let result = try body(index)
                guard try version(of: directory) == before else { continue }
                return result
            } catch {
                // A removal may have raced a stat in the body. Retry the new listing.
                if try version(of: directory) != before { continue }
                throw error
            }
        }
        entries.removeValue(forKey: key)
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "Recording directory changed during bundle collection; retry required"])
    }

    private func version(of directory: URL) throws -> Version {
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard let modified = attrs[.modificationDate] as? Date,
              let inode = attrs[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return Version(modified: modified, inode: inode.uint64Value)
    }
}
