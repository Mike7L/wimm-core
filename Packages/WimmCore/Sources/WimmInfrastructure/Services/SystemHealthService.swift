import Foundation
import WimmDomain

public struct GhostMetadataIssue: Sendable {
    public let baseName: String
    public let metaFileName: String
    public let isCanceled: Bool
    public let processingStatus: String?

    public init(baseName: String, metaFileName: String, isCanceled: Bool, processingStatus: String?) {
        self.baseName = baseName
        self.metaFileName = metaFileName
        self.isCanceled = isCanceled
        self.processingStatus = processingStatus
    }
}

public struct SystemHealthReport: Sendable {
    public let baseDirectory: URL
    public let recordingsDirectory: URL
    public let recordingsDirectoryExists: Bool
    public let writeAccessOK: Bool
    public let writeAccessError: String?
    public let geminiKeyPresent: Bool
    public let geminiKeyLength: Int
    public let openRouterKeyCount: Int
    public let unindexedSessions: [String]
    public let ghostMetadata: [GhostMetadataIssue]
    public let integrityScanError: String?

    public init(
        baseDirectory: URL,
        recordingsDirectory: URL,
        recordingsDirectoryExists: Bool,
        writeAccessOK: Bool,
        writeAccessError: String?,
        geminiKeyPresent: Bool,
        geminiKeyLength: Int,
        openRouterKeyCount: Int,
        unindexedSessions: [String],
        ghostMetadata: [GhostMetadataIssue],
        integrityScanError: String?
    ) {
        self.baseDirectory = baseDirectory
        self.recordingsDirectory = recordingsDirectory
        self.recordingsDirectoryExists = recordingsDirectoryExists
        self.writeAccessOK = writeAccessOK
        self.writeAccessError = writeAccessError
        self.geminiKeyPresent = geminiKeyPresent
        self.geminiKeyLength = geminiKeyLength
        self.openRouterKeyCount = openRouterKeyCount
        self.unindexedSessions = unindexedSessions
        self.ghostMetadata = ghostMetadata
        self.integrityScanError = integrityScanError
    }
}

public actor SystemHealthService {
    private let fileManager = FileManager.default

    public init() {}

    public func evaluate() async -> SystemHealthReport {
        let baseDir = FileStore.baseDirectory()
        let recDir = FileStore.recordingsDirectory()

        let recordingsExists = fileManager.fileExists(atPath: recDir.path)
        let writeCheck = checkWriteAccess(for: recDir)
        let gemini = await geminiKeyStatus()
        let openRouterCount = await OpenRouterKeyRotator.shared.count()
        let integrity = scanIntegrity(in: recDir)

        return SystemHealthReport(
            baseDirectory: baseDir,
            recordingsDirectory: recDir,
            recordingsDirectoryExists: recordingsExists,
            writeAccessOK: writeCheck.ok,
            writeAccessError: writeCheck.error,
            geminiKeyPresent: gemini.present,
            geminiKeyLength: gemini.length,
            openRouterKeyCount: openRouterCount,
            unindexedSessions: integrity.unindexedSessions,
            ghostMetadata: integrity.ghostMetadata,
            integrityScanError: integrity.error
        )
    }

    public func detailedReportText(from report: SystemHealthReport) -> String {
        var output = "Wimm Doctor Report - \(Date())\n"
        output += "================================\n\n"

        if !report.unindexedSessions.isEmpty {
            output += "## Pending Metadata (Unindexed) - \(report.unindexedSessions.count) sessions:\n"
            output += "(These files have content but no .meta.json. Run 'wimm-cli queue --process' to fix.)\n"
            for session in report.unindexedSessions.sorted() {
                output += "- \(session)\n"
            }
            output += "\n"
        }

        if !report.ghostMetadata.isEmpty {
            output += "## Ghost Metadata (Missing Content) - \(report.ghostMetadata.count) files:\n"
            output += "(These are .meta.json files where the .m4a/.pdf/etc is missing.)\n"
            var canceledCount = 0

            for ghost in report.ghostMetadata.sorted(by: { $0.metaFileName < $1.metaFileName }) {
                var status = ""
                if ghost.isCanceled {
                    status = " [CANCELED]"
                    canceledCount += 1
                } else if let processing = ghost.processingStatus, !processing.isEmpty {
                    status = " [\(processing)]"
                }
                output += "- \(ghost.metaFileName)\(status)\n"
            }
            output += "\nTotal Canceled in Orphans: \(canceledCount)\n"
        }

        if let integrityError = report.integrityScanError {
            output += "\n## Integrity Scan Error\n"
            output += "- \(integrityError)\n"
        }

        return output
    }

    private func checkWriteAccess(for recDir: URL) -> (ok: Bool, error: String?) {
        let testFile = recDir.appendingPathComponent(".wimm_doctor_test_\(UUID().uuidString)")
        do {
            try "test".write(to: testFile, atomically: true, encoding: .utf8)
            try fileManager.removeItem(at: testFile)
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func geminiKeyStatus() async -> (present: Bool, length: Int) {
        let key = await APIKeyRotator.shared.currentKey()
        let present = !key.isEmpty && key != "INSERT_KEY_HERE"
        return (present, key.count)
    }

    private func scanIntegrity(in recDir: URL) -> (unindexedSessions: [String], ghostMetadata: [GhostMetadataIssue], error: String?) {
        do {
            let files = try fileManager.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)
            let supportedAudio = FileStore.supportedAudioExtensions
            let supportedDocs = FileStore.supportedDocumentExtensions

            let primaryFiles = Set(files.compactMap { url -> String? in
                let ext = url.pathExtension.lowercased()
                let base = url.deletingPathExtension().lastPathComponent

                if supportedAudio.contains(ext) {
                    return FileStore.strippingDerivedAudioSuffix(base)
                }
                if supportedDocs.contains(ext) {
                    return base
                }
                return nil
            })

            let audioFiles = Set(files.compactMap { url -> String? in
                guard url.pathExtension.lowercased() == "m4a" else { return nil }
                return FileStore.strippingDerivedAudioSuffix(url.deletingPathExtension().lastPathComponent)
            })

            let metaFiles = Set(files.filter {
                $0.pathExtension.lowercased() == "json" && $0.lastPathComponent.contains(".meta")
            }.map {
                $0.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "")
            })

            let unindexed = Array(audioFiles.subtracting(metaFiles)).sorted()
            let ghost = Array(metaFiles.subtracting(primaryFiles)).sorted()

            let issues = ghost.map { base -> GhostMetadataIssue in
                let metaFileName = base + ".meta.json"
                let metaURL = recDir.appendingPathComponent(metaFileName)
                var isCanceled = false
                var processingStatus: String?

                if let data = try? Data(contentsOf: metaURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    isCanceled = (json["isCanceled"] as? Bool) ?? false
                    processingStatus = json["processingStatus"] as? String
                }

                return GhostMetadataIssue(
                    baseName: base,
                    metaFileName: metaFileName,
                    isCanceled: isCanceled,
                    processingStatus: processingStatus
                )
            }

            return (unindexed, issues, nil)
        } catch {
            return ([], [], error.localizedDescription)
        }
    }
}
