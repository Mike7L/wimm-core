import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// One-shot pass that gives already-existing local recordings a sync id and
// queues them.

public struct RecordingBackfillCandidate: Sendable, Hashable {
    public let recordingURL: URL
    public let hasSyncId: Bool
    public let fileCount: Int
    public let totalBytes: UInt64
    public let error: String?

    public init(recordingURL: URL, hasSyncId: Bool, fileCount: Int, totalBytes: UInt64, error: String?) {
        self.recordingURL = recordingURL
        self.hasSyncId = hasSyncId
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.error = error
    }
}

public struct RecordingSyncBackfillOptions: Sendable {
    public var dryRun: Bool
    public var limit: Int?
    public var since: Date?
    public var onlyMissingSyncID: Bool
    public var batchSize: Int

    public init(
        dryRun: Bool = true,
        limit: Int? = nil,
        since: Date? = nil,
        onlyMissingSyncID: Bool = true,
        batchSize: Int = 50
    ) {
        self.dryRun = dryRun
        self.limit = limit
        self.since = since
        self.onlyMissingSyncID = onlyMissingSyncID
        self.batchSize = batchSize
    }
}

public struct RecordingSyncBackfillSummary: Sendable, Hashable {
    public var scanned: Int
    public var eligible: Int
    public var enqueued: Int
    public var skipped: Int
    public var failed: Int
    public var totalBytes: UInt64
    public var failures: [String]

    public init(scanned: Int = 0, eligible: Int = 0, enqueued: Int = 0, skipped: Int = 0, failed: Int = 0, totalBytes: UInt64 = 0, failures: [String] = []) {
        self.scanned = scanned
        self.eligible = eligible
        self.enqueued = enqueued
        self.skipped = skipped
        self.failed = failed
        self.totalBytes = totalBytes
        self.failures = failures
    }
}

public actor RecordingSyncBackfillService {
    private let builder: RecordingBundleBuilder
    private let stateStore: SyncStateStore

    public init(builder: RecordingBundleBuilder = RecordingBundleBuilder(), stateStore: SyncStateStore = SyncStateStore()) {
        self.builder = builder
        self.stateStore = stateStore
    }

    public func run(options: RecordingSyncBackfillOptions) async -> RecordingSyncBackfillSummary {
        await run(options: options, directorySnapshot: RecordingBundleDirectorySnapshot())
    }

    func run(options: RecordingSyncBackfillOptions, directorySnapshot snapshot: RecordingBundleDirectorySnapshot) async -> RecordingSyncBackfillSummary {
        let candidates = recordingCandidates(since: options.since, directorySnapshot: snapshot)
        var summary = RecordingSyncBackfillSummary(scanned: candidates.count)
        var processed = 0
        var prepared: [URL] = []
        let maxCount = min(options.limit ?? Int.max, options.batchSize)

        for url in candidates {
            guard processed < maxCount else { break }
            // Skip already-synced files before collecting bundle contents.
            if options.onlyMissingSyncID && RecordingSyncMetadata.readSyncID(for: url) != nil {
                summary.skipped += 1
                continue
            }
            if options.dryRun {
                let candidate = autoreleasepool { builder.inspect(for: url, directorySnapshot: snapshot) }
                if let error = candidate.error {
                    summary.failed += 1
                    summary.failures.append("\(url.lastPathComponent): \(error)")
                    continue
                }
                if options.onlyMissingSyncID && candidate.hasSyncId {
                    summary.skipped += 1
                    continue
                }
                summary.eligible += 1
                summary.totalBytes += candidate.totalBytes
                processed += 1
                continue
            }

            summary.eligible += 1
            processed += 1
            do {
                // Finish our own sidecar creations/replacements before taking
                // the bundle listing. Otherwise each atomic write invalidates it.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw RecordingSyncError.missingPrimaryFile(url)
                }
                try RecordingSyncMetadata.ensureSyncID(for: url)
                prepared.append(url)
            } catch {
                summary.failed += 1
                summary.failures.append("\(url.lastPathComponent): \(error)")
            }
        }

        // Applied backfill collects and stats each bundle only once.
        for url in prepared {
            do {
                let bundle = try builder.build(for: url, assignSyncID: false, directorySnapshot: snapshot)
                summary.totalBytes += bundle.manifest.files.reduce(UInt64(0)) { $0 + $1.byteSize }
                try await stateStore.enqueueUpload(
                    syncId: bundle.manifest.syncId,
                    localURL: url,
                    updatedAt: bundle.manifest.updatedAt
                )
                summary.enqueued += 1
            } catch {
                summary.failed += 1
                summary.failures.append("\(url.lastPathComponent): \(error)")
            }
        }

        return summary
    }

    private func recordingCandidates(since: Date?, directorySnapshot: RecordingBundleDirectorySnapshot) -> [URL] {
        let dir = FileStore.recordingsDirectory()
        let contents = ((try? directorySnapshot.fileURLs(in: dir)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }

        let supported = contents
            .filter { FileStore.isSupportedRecordingFile($0) }
            .filter { !FileStore.isDerivedAudioFile($0) }
            .filter { !FileStore.isAttachmentFile($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true }

        // A PDF's rendered first page ("{base}.heic") and HUD screen grabs already travel
        // inside their owner's bundle as `.screenshot` files. Offered as candidates they
        // would upload a second time as a primary of their own — under the *same* syncId,
        // since the sidecar is shared — and the note would race itself between devices.
        let ownerBases = Set(
            supported
                .filter { FileStore.previewImageSessionBase($0) == nil }
                .map { $0.deletingPathExtension().lastPathComponent }
        )

        let primaries = supported.filter { url in
            guard let base = FileStore.previewImageSessionBase(url) else { return true }
            return !ownerBases.contains(base)
        }
        let dated: [(url: URL, modified: Date)] = primaries.map {
            (url: $0, modified: FileStore.fileModificationDate($0))
        }
        let eligible = dated.filter { candidate in
            guard let since else { return true }
            return candidate.modified >= since
        }
        return eligible.sorted { lhs, rhs in
            if lhs.modified == rhs.modified {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.modified < rhs.modified
        }.map { $0.url }
    }
}
