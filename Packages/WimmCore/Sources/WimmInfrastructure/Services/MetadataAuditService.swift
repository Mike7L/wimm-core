import Foundation
import WimmDomain
import AVFoundation
import CoreMedia

public struct MetaValidationIssue: Codable, Sendable {
    public let file: String
    public let code: String
    public let message: String
    public let fixed: Bool

    public init(file: String, code: String, message: String, fixed: Bool) {
        self.file = file
        self.code = code
        self.message = message
        self.fixed = fixed
    }
}

public struct MetaValidationReport: Codable, Sendable {
    public let scannedFiles: Int
    public let warnings: Int
    public let errors: Int
    public let fixed: Int
    public let issues: [MetaValidationIssue]

    public init(scannedFiles: Int, warnings: Int, errors: Int, fixed: Int, issues: [MetaValidationIssue]) {
        self.scannedFiles = scannedFiles
        self.warnings = warnings
        self.errors = errors
        self.fixed = fixed
        self.issues = issues
    }
}

public struct AttachmentAuditEntry: Codable, Sendable {
    public let file: String
    public let total: Int
    public let invalidURL: Int
    public let missingFiles: Int
    public let missingOCR: Int

    public init(file: String, total: Int, invalidURL: Int, missingFiles: Int, missingOCR: Int) {
        self.file = file
        self.total = total
        self.invalidURL = invalidURL
        self.missingFiles = missingFiles
        self.missingOCR = missingOCR
    }
}

public struct AttachmentAuditReport: Codable, Sendable {
    public let scannedFiles: Int
    public let entriesWithFindings: Int
    public let invalidURL: Int
    public let missingFiles: Int
    public let missingOCR: Int
    public let entries: [AttachmentAuditEntry]

    public init(
        scannedFiles: Int,
        entriesWithFindings: Int,
        invalidURL: Int,
        missingFiles: Int,
        missingOCR: Int,
        entries: [AttachmentAuditEntry]
    ) {
        self.scannedFiles = scannedFiles
        self.entriesWithFindings = entriesWithFindings
        self.invalidURL = invalidURL
        self.missingFiles = missingFiles
        self.missingOCR = missingOCR
        self.entries = entries
    }
}

public struct TranscriptRebuildItem: Codable, Sendable {
    public let file: String
    public let status: String
    public let message: String

    public init(file: String, status: String, message: String) {
        self.file = file
        self.status = status
        self.message = message
    }
}

public struct TranscriptRebuildReport: Codable, Sendable {
    public let total: Int
    public let rebuilt: Int
    public let skipped: Int
    public let failed: Int
    public let items: [TranscriptRebuildItem]

    public init(total: Int, rebuilt: Int, skipped: Int, failed: Int, items: [TranscriptRebuildItem]) {
        self.total = total
        self.rebuilt = rebuilt
        self.skipped = skipped
        self.failed = failed
        self.items = items
    }
}

public actor MetadataAuditService {
    private let fileRepository: FileRepositoryProtocol
    private let transcriptRepository: TranscriptRepositoryProtocol
    private let fileManager = FileManager.default

    public init(
        fileRepository: FileRepositoryProtocol = FileRepository(),
        transcriptRepository: TranscriptRepositoryProtocol = TranscriptRepository()
    ) {
        self.fileRepository = fileRepository
        self.transcriptRepository = transcriptRepository
    }

    public func validateAll(fix: Bool) async -> MetaValidationReport {
        let files = await fileRepository.recordings(order: .descending)
        var warnings = 0
        var errors = 0
        var fixedCount = 0
        var issues: [MetaValidationIssue] = []

        for file in files {
            let metaURL = FileStore.metadataURL(forRecordingURL: file)
            let fileLabel = file.lastPathComponent

            if !fileManager.fileExists(atPath: metaURL.path) {
                errors += 1
                var didFix = false
                if fix {
                    // mutateSidecar re-reads under the lock, so a sidecar created
                    // by another writer in the meantime is kept, not blanked.
                    didFix = (try? FileStore.mutateSidecar(at: metaURL) { _ in true }) != nil
                    if didFix { fixedCount += 1 }
                }
                issues.append(MetaValidationIssue(
                    file: fileLabel,
                    code: "missing_metadata",
                    message: "Missing metadata file",
                    fixed: didFix
                ))
                continue
            }

            guard let data = try? Data(contentsOf: metaURL) else {
                errors += 1
                issues.append(MetaValidationIssue(
                    file: fileLabel,
                    code: "metadata_read_failed",
                    message: "Failed to read metadata file",
                    fixed: false
                ))
                continue
            }

            guard var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                errors += 1
                issues.append(MetaValidationIssue(
                    file: fileLabel,
                    code: "metadata_invalid_json",
                    message: "Metadata file is not a valid JSON object",
                    fixed: false
                ))
                continue
            }

            var modified = false

            let redundant = Set(json.keys).intersection(FileStore.redundantMetaJSONKeys)
            if !redundant.isEmpty {
                warnings += 1
                issues.append(MetaValidationIssue(
                    file: fileLabel,
                    code: "redundant_keys_present",
                    message: "Redundant keys present: \(redundant.sorted().joined(separator: ", "))",
                    fixed: false
                ))
                if fix {
                    for key in redundant {
                        json.removeValue(forKey: key)
                    }
                    modified = true
                }
            }

            if let legacyTranscription = json["transcription"] as? String {
                let trimmed = legacyTranscription.trimmingCharacters(in: .whitespacesAndNewlines)
                warnings += 1
                issues.append(MetaValidationIssue(
                    file: fileLabel,
                    code: "legacy_transcription_string",
                    message: "transcription is string instead of object",
                    fixed: false
                ))
                if fix, !trimmed.isEmpty {
                    json["transcription"] = [
                        "transcript": trimmed,
                        "speechStatus": TranscriptionSpeechStatus.speech.rawValue,
                    ]
                    modified = true
                }
            }

            if let attachments = json["attachments"], !(attachments is [[String: Any]]) {
                errors += 1
                issues.append(MetaValidationIssue(
                    file: fileLabel,
                    code: "attachments_invalid_shape",
                    message: "attachments must be an array of objects",
                    fixed: false
                ))
            }

            if modified {
                // Re-apply the same idempotent repairs to a fresh read under the
                // sidecar lock instead of writing back the copy read at the top of
                // this iteration — that copy is stale if any other writer (sync,
                // transcription, analysis) touched the file in between.
                let wrote = (try? FileStore.mutateSidecar(at: metaURL) { fresh in
                    Self.applyRepairs(to: &fresh)
                }) != nil
                if wrote {
                    fixedCount += 1
                    if let idx = issues.lastIndex(where: { $0.file == fileLabel && $0.fixed == false && ($0.code == "redundant_keys_present" || $0.code == "legacy_transcription_string") }) {
                        let old = issues[idx]
                        issues[idx] = MetaValidationIssue(file: old.file, code: old.code, message: old.message, fixed: true)
                    }
                }
            }
        }

        return MetaValidationReport(
            scannedFiles: files.count,
            warnings: warnings,
            errors: errors,
            fixed: fixedCount,
            issues: issues
        )
    }

    public func auditAttachments() async -> AttachmentAuditReport {
        let files = await fileRepository.recordings(order: .descending)
        var entries: [AttachmentAuditEntry] = []
        var totalInvalidURL = 0
        var totalMissingFiles = 0
        var totalMissingOCR = 0

        for file in files {
            let metaURL = FileStore.metadataURL(forRecordingURL: file)
            guard let data = try? Data(contentsOf: metaURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let attachments = json["attachments"] as? [[String: Any]],
                  !attachments.isEmpty else {
                continue
            }

            var invalidURL = 0
            var missingFiles = 0
            var missingOCR = 0

            for attachment in attachments {
                guard let rawURL = attachment["url"] as? String, let url = URL(string: rawURL) else {
                    invalidURL += 1
                    continue
                }

                if !url.isFileURL {
                    invalidURL += 1
                } else if !fileManager.fileExists(atPath: url.path) {
                    missingFiles += 1
                }

                let extracted = (
                    (attachment["extractedText"] as? String)
                        ?? (attachment["ocrText"] as? String)
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if extracted.isEmpty {
                    missingOCR += 1
                }
            }

            if invalidURL > 0 || missingFiles > 0 || missingOCR > 0 {
                entries.append(AttachmentAuditEntry(
                    file: file.lastPathComponent,
                    total: attachments.count,
                    invalidURL: invalidURL,
                    missingFiles: missingFiles,
                    missingOCR: missingOCR
                ))
            }

            totalInvalidURL += invalidURL
            totalMissingFiles += missingFiles
            totalMissingOCR += missingOCR
        }

        return AttachmentAuditReport(
            scannedFiles: files.count,
            entriesWithFindings: entries.count,
            invalidURL: totalInvalidURL,
            missingFiles: totalMissingFiles,
            missingOCR: totalMissingOCR,
            entries: entries
        )
    }

    public func rebuildTranscripts(path: String?, all: Bool) async -> TranscriptRebuildReport {
        var targets: [URL] = []

        if all {
            targets = await fileRepository.recordings(order: .descending)
        } else if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let file = URL(fileURLWithPath: expanded).standardizedFileURL
            targets = [file]
        }

        var rebuilt = 0
        var skipped = 0
        var failed = 0
        var items: [TranscriptRebuildItem] = []

        for file in targets {
            let label = file.lastPathComponent
            guard FileStore.isAudioFile(file) else {
                skipped += 1
                items.append(TranscriptRebuildItem(file: label, status: "skipped", message: "Not an audio file"))
                continue
            }

            let current = await transcriptRepository.transcriptText(for: file)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if current.isEmpty {
                skipped += 1
                items.append(TranscriptRebuildItem(file: label, status: "skipped", message: "No transcript text found"))
                continue
            }

            let duration = await Self.audioDuration(for: file)
            do {
                try await transcriptRepository.updateTranscriptText(text: current, duration: duration, to: file)
                rebuilt += 1
                items.append(TranscriptRebuildItem(file: label, status: "rebuilt", message: "Transcript normalized and saved"))
            } catch {
                failed += 1
                items.append(TranscriptRebuildItem(file: label, status: "failed", message: error.localizedDescription))
            }
        }

        return TranscriptRebuildReport(
            total: targets.count,
            rebuilt: rebuilt,
            skipped: skipped,
            failed: failed,
            items: items
        )
    }

    private static func audioDuration(for file: URL) async -> Double {
        let duration = try? await AVURLAsset(url: file).load(.duration)
        let seconds = duration.map { CMTimeGetSeconds($0) } ?? 3600.0
        return seconds.isFinite && seconds > 0 ? seconds : 3600.0
    }

    /// The two repairs `validate(fix:)` makes, as one idempotent mutation.
    /// Returns whether anything changed.
    private static func applyRepairs(to json: inout [String: Any]) -> Bool {
        var changed = false
        for key in Set(json.keys).intersection(FileStore.redundantMetaJSONKeys) {
            json.removeValue(forKey: key)
            changed = true
        }
        if let legacy = json["transcription"] as? String {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                json["transcription"] = [
                    "transcript": trimmed,
                    "speechStatus": TranscriptionSpeechStatus.speech.rawValue,
                ]
                changed = true
            }
        }
        return changed
    }
}
