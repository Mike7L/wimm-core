import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct MetaMigrateAttachments: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-attachments",
        abstract: "Migrate legacy attachment OCR keys (ocr*) to extracted* in metadata files"
    )

    @Flag(name: .long, help: "Apply changes (default is dry-run)")
    var apply: Bool = false

    @Option(
        name: .long,
        help: "Optional path to a recording file or a .meta.json/.metadata.json file"
    )
    var path: String?

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Exit non-zero when parse/write errors are found")
    var strict: Bool = false

    func run() async throws {
        let fm = FileManager.default
        let targets = try resolveMetaFiles(using: fm)

        var report = AttachmentMigrationReport(
            dryRun: !apply,
            targetPath: path,
            scannedMetaFiles: 0,
            withAttachments: 0,
            withoutAttachments: 0,
            filesNeedingMigration: 0,
            filesMigrated: 0,
            entriesMigrated: 0,
            parseErrors: [],
            writeErrors: [],
            changedFiles: []
        )

        for metaURL in targets {
            report.scannedMetaFiles += 1

            let data: Data
            do {
                data = try Data(contentsOf: metaURL)
            } catch {
                report.parseErrors.append(.init(metaFile: metaURL.lastPathComponent, error: error.localizedDescription))
                continue
            }

            let root: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    report.parseErrors.append(.init(metaFile: metaURL.lastPathComponent, error: "Root JSON is not an object"))
                    continue
                }
                root = parsed
            } catch {
                report.parseErrors.append(.init(metaFile: metaURL.lastPathComponent, error: error.localizedDescription))
                continue
            }

            guard let attachments = root["attachments"] as? [[String: Any]], !attachments.isEmpty else {
                report.withoutAttachments += 1
                continue
            }
            report.withAttachments += 1

            let changedEntries = attachments.filter { migrateAttachment($0).changed }.count

            guard changedEntries > 0 else { continue }

            report.filesNeedingMigration += 1
            report.entriesMigrated += changedEntries
            report.changedFiles.append(.init(
                metaFile: metaURL.lastPathComponent,
                migratedEntries: changedEntries,
                totalAttachments: attachments.count
            ))

            if !apply { continue }

            // Through the shared sidecar door: it re-reads under the lock and
            // migrates the attachments it finds then, so keys other writers
            // added since the scan read are kept. (The lock is in-process; it
            // does not coordinate with a running Wimm app.)
            do {
                try FileStore.mutateSidecar(at: metaURL) { fresh in
                    guard let current = fresh["attachments"] as? [[String: Any]] else { return false }
                    fresh["attachments"] = current.map { migrateAttachment($0).value }
                    return true
                }
                report.filesMigrated += 1
            } catch {
                report.writeErrors.append(.init(metaFile: metaURL.lastPathComponent, error: error.localizedDescription))
            }
        }

        if json {
            try printJSON(report)
        } else {
            print("Attachment metadata migration")
            print("Mode: \(apply ? "APPLY" : "DRY-RUN")")
            print("Scanned .meta files: \(report.scannedMetaFiles)")
            print("With attachments: \(report.withAttachments)")
            print("Without attachments: \(report.withoutAttachments)")
            print("Files needing migration: \(report.filesNeedingMigration)")
            print("Migrated files: \(report.filesMigrated)")
            print("Migrated attachment entries: \(report.entriesMigrated)")
            print("Parse errors: \(report.parseErrors.count)")
            print("Write errors: \(report.writeErrors.count)")

            if !report.changedFiles.isEmpty {
                print("\nSample changed files:")
                for item in report.changedFiles.prefix(20) {
                    print("- \(item.metaFile): \(item.migratedEntries)/\(item.totalAttachments) attachment(s)")
                }
                if report.changedFiles.count > 20 {
                    print("- ... and \(report.changedFiles.count - 20) more")
                }
            }

            if !report.parseErrors.isEmpty {
                print("\nParse errors:")
                for err in report.parseErrors.prefix(20) {
                    print("- \(err.metaFile): \(err.error)")
                }
            }

            if !report.writeErrors.isEmpty {
                print("\nWrite errors:")
                for err in report.writeErrors.prefix(20) {
                    print("- \(err.metaFile): \(err.error)")
                }
            }

            if !apply {
                print("\nRun with --apply to persist changes.")
            }
        }

        if strict && (!report.parseErrors.isEmpty || !report.writeErrors.isEmpty) {
            throw ExitCode(1)
        }
    }

    private func resolveMetaFiles(using fm: FileManager) throws -> [URL] {
        if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            if isMetaFile(url) { return [url] }
            return [FileStore.metadataURL(forRecordingURL: url)]
        }

        var dirs: [URL] = [FileStore.recordingsDirectory()]
        let legacy = FileStore.legacyRecordingsDirectory()
        var isDir: ObjCBool = false
        if legacy != dirs[0], fm.fileExists(atPath: legacy.path, isDirectory: &isDir), isDir.boolValue {
            dirs.append(legacy)
        }

        var collected: [URL] = []
        for dir in dirs {
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            collected.append(contentsOf: files.filter(isMetaFile))
        }

        return Array(Set(collected.map { $0.standardizedFileURL.path }))
            .sorted()
            .map { URL(fileURLWithPath: $0) }
    }

    private func isMetaFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".meta.json") || name.hasSuffix(".metadata.json")
    }

    private func migrateAttachment(_ dict: [String: Any]) -> (value: [String: Any], changed: Bool) {
        var out = dict
        var changed = false

        if out["extractedText"] == nil, let legacy = out["ocrText"] {
            out["extractedText"] = legacy
            changed = true
        }
        if out["extractionProvider"] == nil, let legacy = out["ocrProvider"] {
            out["extractionProvider"] = legacy
            changed = true
        }
        if out["extractionModel"] == nil, let legacy = out["ocrModel"] {
            out["extractionModel"] = legacy
            changed = true
        }

        if out.removeValue(forKey: "ocrText") != nil { changed = true }
        if out.removeValue(forKey: "ocrProvider") != nil { changed = true }
        if out.removeValue(forKey: "ocrModel") != nil { changed = true }

        return (out, changed)
    }
}

private struct AttachmentMigrationError: Codable {
    let metaFile: String
    let error: String
}

private struct AttachmentMigrationFileResult: Codable {
    let metaFile: String
    let migratedEntries: Int
    let totalAttachments: Int
}

private struct AttachmentMigrationReport: Codable {
    let dryRun: Bool
    let targetPath: String?
    var scannedMetaFiles: Int
    var withAttachments: Int
    var withoutAttachments: Int
    var filesNeedingMigration: Int
    var filesMigrated: Int
    var entriesMigrated: Int
    var parseErrors: [AttachmentMigrationError]
    var writeErrors: [AttachmentMigrationError]
    var changedFiles: [AttachmentMigrationFileResult]
}

private func printJSON<T: Encodable>(_ payload: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(payload)
    if let output = String(data: data, encoding: .utf8) {
        print(output)
    }
}
