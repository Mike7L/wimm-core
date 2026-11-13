import Foundation
import WimmDomain

public struct AudioImportEntryResult: Sendable {
    public let sourcePath: String
    public let destinationPath: String?
    public let success: Bool
    public let error: String?

    public init(sourcePath: String, destinationPath: String?, success: Bool, error: String?) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.success = success
        self.error = error
    }
}

public struct AudioImportBatchSummary: Sendable {
    public let found: Int
    public let imported: Int
    public let failed: Int
    public let importedPaths: [String]
    public let failures: [AudioImportEntryResult]

    public init(found: Int, imported: Int, failed: Int, importedPaths: [String], failures: [AudioImportEntryResult]) {
        self.found = found
        self.imported = imported
        self.failed = failed
        self.importedPaths = importedPaths
        self.failures = failures
    }
}

public struct AudioImportService {
    private let fileManager = FileManager.default

    public init() {}

    public func importBatch(
        urls: [URL],
        progress: (@Sendable (Int, Int, URL) -> Void)? = nil
    ) async -> AudioImportBatchSummary {
        guard !urls.isEmpty else {
            return AudioImportBatchSummary(found: 0, imported: 0, failed: 0, importedPaths: [], failures: [])
        }

        let total = urls.count
        var importedPaths: [String] = []
        var failures: [AudioImportEntryResult] = []

        for (index, source) in urls.enumerated() {
            progress?(index + 1, total, source)
            let result = await importSingle(source: source)
            if result.success, let destinationPath = result.destinationPath {
                importedPaths.append(destinationPath)
            } else {
                failures.append(result)
            }
        }

        return AudioImportBatchSummary(
            found: total,
            imported: importedPaths.count,
            failed: failures.count,
            importedPaths: importedPaths,
            failures: failures
        )
    }

    public func importSingle(source: URL) async -> AudioImportEntryResult {
        let destDir = FileStore.recordingsDirectory()
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = FileStore.uniqueDestinationURL(for: source, in: destDir, baseFallback: "import")

        do {
            try fileManager.copyItem(at: source, to: dest)
            let sourceCreated = (try? FileStore.fileCreationDate(source)) ?? Date()
            let sourceModified = FileStore.fileModificationDate(source)
            _ = FileStore.trySetFileDates(dest, created: sourceCreated, modified: sourceModified)

            FileStore.upsertMetadata(for: dest, updates: [
                MetadataKey.sourcePath.rawValue: source.path
            ])
            if let syncService = CloudRecordingSyncService.live() {
                do {
                    _ = try await syncService.enqueueNewRecording(dest)
                    try await syncService.uploadPending()
                } catch {
                    // Sync is best-effort during import; the local file remains the source of truth.
                }
            }

            return AudioImportEntryResult(
                sourcePath: source.path,
                destinationPath: dest.path,
                success: true,
                error: nil
            )
        } catch {
            return AudioImportEntryResult(
                sourcePath: source.path,
                destinationPath: nil,
                success: false,
                error: String(describing: error)
            )
        }
    }
}
