import Foundation
import WimmDomain
import CryptoKit

public enum ImportPlanningKind: String, Codable, CaseIterable, Sendable {
    case pdf
    case docx
    case image
    case audio
    case text
    case enex
    case other

    public var isImportable: Bool {
        self != .other
    }
}

public enum ImportPlanningDuplicateReason: String, Codable, Sendable {
    case alreadyImported
    case duplicateInSelection
}

public struct ImportPlanningDuplicate: Sendable {
    public let url: URL
    public let reason: ImportPlanningDuplicateReason
    public let match: URL?

    public init(url: URL, reason: ImportPlanningDuplicateReason, match: URL?) {
        self.url = url
        self.reason = reason
        self.match = match
    }
}

public struct ImportPlanningGroup: Sendable {
    public let kind: ImportPlanningKind
    public let urls: [URL]
    public let duplicates: [ImportPlanningDuplicate]

    public init(kind: ImportPlanningKind, urls: [URL], duplicates: [ImportPlanningDuplicate]) {
        self.kind = kind
        self.urls = urls
        self.duplicates = duplicates
    }
}

public struct ImportPlanningResult: Sendable {
    public let groups: [ImportPlanningGroup]
    public let totalCount: Int
    public let duplicateCount: Int

    public init(groups: [ImportPlanningGroup], totalCount: Int, duplicateCount: Int) {
        self.groups = groups
        self.totalCount = totalCount
        self.duplicateCount = duplicateCount
    }
}

public struct ImportPlanningService {
    private let fileManager = FileManager.default

    public init() {}

    public func collectCandidates(from urls: [URL]) -> [URL] {
        collectCandidates(from: urls, progress: nil)
    }

    public func collectCandidates(
        from urls: [URL],
        progress: (@Sendable (_ found: Int, _ currentURL: URL?) -> Void)?
    ) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        var results: [URL] = []
        var seen: Set<String> = []

        for url in urls {
            progress?(results.count, url)
            if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: keys),
                          values.isRegularFile == true else { continue }
                    if seen.insert(fileURL.path).inserted {
                        results.append(fileURL)
                        if results.count == 1 || results.count.isMultiple(of: 25) {
                            progress?(results.count, fileURL)
                        }
                    }
                }
            } else if (try? url.resourceValues(forKeys: keys).isRegularFile) == true {
                if seen.insert(url.path).inserted {
                    results.append(url)
                    progress?(results.count, url)
                }
            }
        }

        progress?(results.count, results.last)
        return results
    }

    public func plan(from candidates: [URL]) -> ImportPlanningResult {
        let sortedCandidates = candidates.sorted { $0.path < $1.path }

        // Size prefilter: identical content implies identical byte size, so
        // only files whose sizes collide can be duplicates. Stat everything
        // first (cheap) and reserve SHA256 for the rare collisions — hashing
        // the whole multi-GB library on every import took minutes.
        let candidateSizes = sortedCandidates.map { fileSize(for: $0) }
        var candidateSizeCounts: [Int64: Int] = [:]
        for size in candidateSizes {
            if let size { candidateSizeCounts[size, default: 0] += 1 }
        }

        let existingCollisions = existingImportableFiles().filter { file in
            // Unknown size → hash conservatively rather than miss a duplicate.
            guard let size = fileSize(for: file) else { return true }
            return candidateSizeCounts[size] != nil
        }
        let existingSizes = Set(existingCollisions.compactMap { fileSize(for: $0) })

        var existingHashes: [String: URL] = [:]
        for (file, hash) in zip(existingCollisions, parallelHashes(for: existingCollisions.map(Optional.some))) {
            guard let hash else { continue }
            if existingHashes[hash] == nil {
                existingHashes[hash] = file
            }
        }

        // A candidate only needs hashing when its size matches an existing
        // file or repeats within the selection; a nil hash below means
        // "provably unique", which the dedup loop already treats as such.
        let hashCandidates = zip(sortedCandidates, candidateSizes).map { url, size -> URL? in
            guard let size else { return url }
            let collides = existingSizes.contains(size) || (candidateSizeCounts[size] ?? 0) > 1
            return collides ? url : nil
        }
        let candidateHashes = parallelHashes(for: hashCandidates)

        var seenCandidateHashes: [String: URL] = [:]
        var groups: [ImportPlanningKind: (urls: [URL], duplicates: [ImportPlanningDuplicate])] = [:]
        var duplicateCount = 0

        for (index, url) in sortedCandidates.enumerated() {
            let kind = kind(for: url)
            let hash = candidateHashes[index]
            var isDuplicate = false

            if let hash, let existing = existingHashes[hash] {
                groups[kind, default: ([], [])].duplicates.append(
                    ImportPlanningDuplicate(url: url, reason: .alreadyImported, match: existing)
                )
                duplicateCount += 1
                isDuplicate = true
            } else if let hash, let first = seenCandidateHashes[hash] {
                groups[kind, default: ([], [])].duplicates.append(
                    ImportPlanningDuplicate(url: url, reason: .duplicateInSelection, match: first)
                )
                duplicateCount += 1
                isDuplicate = true
            }

            if !isDuplicate {
                groups[kind, default: ([], [])].urls.append(url)
                if let hash {
                    seenCandidateHashes[hash] = url
                }
            }
        }

        let grouped = groups
            .map {
                ImportPlanningGroup(
                    kind: $0.key,
                    urls: $0.value.urls.sorted { $0.path < $1.path },
                    duplicates: $0.value.duplicates.sorted { $0.url.path < $1.url.path }
                )
            }
            .sorted { sortOrder(for: $0.kind) < sortOrder(for: $1.kind) }

        return ImportPlanningResult(groups: grouped, totalCount: sortedCandidates.count, duplicateCount: duplicateCount)
    }

    public func kind(for url: URL) -> ImportPlanningKind {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if AttachmentTypeHelper.officeExtensions.contains(ext) { return .docx }
        if AttachmentTypeHelper.imageExtensions.contains(ext) { return .image }
        if FileStore.supportedAudioExtensions.contains(ext) { return .audio }
        if AttachmentTypeHelper.textExtensions.contains(ext) { return .text }
        if ext == "enex" { return .enex }
        return .other
    }

    private func existingImportableFiles() -> [URL] {
        let dir = FileStore.recordingsDirectory()
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.filter { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return kind(for: url).isImportable
        }
    }

    private func sortOrder(for kind: ImportPlanningKind) -> Int {
        switch kind {
        case .pdf: return 0
        case .docx: return 1
        case .image: return 2
        case .audio: return 3
        case .text: return 4
        case .enex: return 5
        case .other: return 6
        }
    }

    private func fileSize(for url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Hashes the non-nil entries concurrently; nil entries pass through as
    /// nil hashes. Distinct-index writes into the buffer are race-free.
    private func parallelHashes(for urls: [URL?]) -> [String?] {
        guard !urls.isEmpty else { return [] }
        var results = [String?](repeating: nil, count: urls.count)
        results.withUnsafeMutableBufferPointer { buffer in
            // concurrentPerform joins before the buffer goes out of scope.
            nonisolated(unsafe) let base = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                guard let url = urls[index] else { return }
                base[index] = Self.computeFileHash(for: url)
            }
        }
        return results
    }

    private static func computeFileHash(for url: URL) -> String? {
        guard let stream = InputStream(url: url) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
