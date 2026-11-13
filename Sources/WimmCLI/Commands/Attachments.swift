import ArgumentParser
import CryptoKit
import Foundation
import ImageIO
import WimmInfrastructure
import WimmDomain
import WimmTranscription

struct Attachments: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attachment tools",
        subcommands: [
            AttachmentsAudit.self,
            AttachmentsTranscribeEvernote.self,
            AttachmentsAnalyzeEvernoteAudio.self,
            AttachmentsOCREvernote.self,
        ]
    )
}

struct AttachmentsAnalyzeEvernoteAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze-evernote-audio",
        abstract: "Rebuild analysis for Evernote notes with audio transcripts"
    )

    @Flag(name: .long, help: "Persist rebuilt analysis; without this flag only report candidates")
    var apply: Bool = false

    @Option(name: .long, help: "Process at most this many eligible notes")
    var limit: Int?

    @Option(name: .long, help: "Override the analysis model for this run")
    var model: String?

    @Flag(name: .long, help: "Notes whose photos/PDFs got text from `ocr-evernote`: analyze them with audio and OCR text")
    var includeOcr: Bool = false

    func run() async throws {
        if let limit, limit < 1 { throw ValidationError("--limit must be greater than zero") }

        let scanner = EvernoteAudioAttachmentScanner()
        let scan = try scanner.scanForAnalysis(limit: limit, includeOCR: includeOcr)
        let backfillKey = includeOcr ? "evernoteAttachments" : "evernoteAudio"
        print("Evernote \(includeOcr ? "attachment (audio + OCR)" : "audio") analysis backfill\(apply ? " [apply]" : " [dry-run]")")
        print("Evernote notes: \(scan.evernoteNotes)")
        print("Notes with \(includeOcr ? "OCR text" : "audio transcripts"): \(scan.notesWithAudioTranscripts)")
        print("No-speech-only notes: \(scan.noSpeechOnlyNotes)")
        print("Already analyzed for current transcripts: \(scan.alreadyAnalyzed)")
        print("Missing note files: \(scan.missingNoteFiles)")
        print("Eligible: \(scan.candidates.count)")
        if includeOcr {
            let chars = scan.candidates.reduce(0) { $0 + $1.contextChars }
            print("Attachment text to send: \(chars) chars (~\(chars / 4) tokens before note text)")
        }

        guard apply, !scan.candidates.isEmpty else {
            if !apply { print("Run again with --apply to rebuild analysis for these notes.") }
            return
        }

        let metadataRepository = MetadataRepository()
        let backupDirectory = try scanner.makeAnalysisBackupDirectory()
        var succeeded = 0
        var failed = 0

        for (offset, candidate) in scan.candidates.enumerated() {
            print("[\(offset + 1)/\(scan.candidates.count)] \(candidate.noteURL.lastPathComponent)")
            do {
                try scanner.backUpMetadata(for: candidate.noteURL, to: backupDirectory)
                var requestContext = [
                    "origin": "WimmCLI.AttachmentsAnalyzeEvernoteAudio",
                    "reason": includeOcr ? "Evernote attachment OCR analysis backfill"
                                         : "Evernote audio transcript analysis backfill",
                ]
                if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !model.isEmpty
                {
                    requestContext["model"] = model
                }
                let card = try await NoteProcessor.shared.reprocess(
                    file: candidate.noteURL,
                    requestContext: requestContext
                )

                guard card.provider?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      card.model_used?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                else {
                    try scanner.restoreMetadata(for: candidate.noteURL, from: backupDirectory)
                    failed += 1
                    print("  Failed: LLM returned fallback analysis; original metadata restored")
                    continue
                }

                var metadata = await metadataRepository.metadata(for: candidate.noteURL)
                var backfills = metadata["analysisBackfills"] as? [String: Any] ?? [:]
                backfills[backfillKey] = [
                    "transcriptHash": candidate.transcriptHash,
                    "analyzedAt": ISO8601.now,
                    "provider": card.provider ?? "",
                    "model": card.model_used ?? "",
                ]
                metadata = ["analysisBackfills": backfills]
                await metadataRepository.upsertMetadata(for: candidate.noteURL, updates: metadata)
                succeeded += 1
                print("  Saved: \(card.title)")
            } catch {
                try? scanner.restoreMetadata(for: candidate.noteURL, from: backupDirectory)
                failed += 1
                print("  Failed: \(error.localizedDescription); original metadata restored")
            }
        }

        print("Analysis backfill complete: succeeded=\(succeeded) failed=\(failed)")
        print("Metadata backups: \(backupDirectory.path)")
        if failed > 0 { throw ExitCode.failure }
    }
}

struct AttachmentsTranscribeEvernote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe-evernote",
        abstract: "Backfill missing transcripts for Evernote audio attachments"
    )

    @Flag(name: .long, help: "Persist transcripts; without this flag only report candidates")
    var apply: Bool = false

    @Option(name: .long, help: "Engine: gemini or openrouter")
    var engine: String = "gemini"

    @Option(name: .long, help: "Override transcription model")
    var model: String?

    @Option(name: .long, help: "Spoken language hint")
    var lang: String = "Auto"

    @Option(name: .long, help: "Process at most this many eligible attachments")
    var limit: Int?

    func run() async throws {
        guard let engineID = EngineID(rawValue: engine.lowercased()), engineID != .native else {
            throw ValidationError("Engine must be gemini or openrouter")
        }
        if let limit, limit < 1 { throw ValidationError("--limit must be greater than zero") }

        let scanner = EvernoteAudioAttachmentScanner()
        let scan = try scanner.scan(limit: limit)
        print("Evernote audio attachment backfill\(apply ? " [apply]" : " [dry-run]")")
        print("Evernote notes: \(scan.evernoteNotes)")
        print("Audio attachments: \(scan.audioAttachments)")
        print("Already transcribed: \(scan.alreadyTranscribed)")
        print("Missing files: \(scan.missingFiles)")
        print("Eligible: \(scan.candidates.count)")

        guard apply, !scan.candidates.isEmpty else {
            if !apply { print("Run again with --apply to transcribe these files.") }
            return
        }

        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Config.transcribeModel
        let service = TranscriptionService(
            rotator: .shared,
            model: selectedModel,
            transport: .shared
        )
        let metadataRepository = MetadataRepository()
        let attachmentRepository = AttachmentRepository(metadataRepository: metadataRepository)
        let backupDirectory = try scanner.makeBackupDirectory()
        var backedUpNotes = Set<URL>()
        var succeeded = 0
        var failed = 0
        var pausedForOfflineNetwork = false

        candidateLoop: for (offset, candidate) in scan.candidates.enumerated() {
            print("[\(offset + 1)/\(scan.candidates.count)] \(candidate.attachmentURL.lastPathComponent)")
            let result = await service.transcribe(
                file: candidate.attachmentURL,
                engine: engineID,
                model: selectedModel,
                language: lang
            )

            switch result {
            case .success(let rawText):
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                // TranscriptionService strips the model's [[NO_SPEECH]] sentinel
                // before returning. Persist the sentinel on the parent attachment so
                // a confirmed silent/noise-only clip is completed, not retried forever.
                let text = trimmed.isEmpty ? TranscriptionSupport.noSpeechSentinel : trimmed

                var attachments = await attachmentRepository.attachments(for: candidate.noteURL)
                guard let index = attachments.firstIndex(where: { $0.id == candidate.attachmentID }) else {
                    failed += 1
                    print("  Failed: attachment metadata changed during run")
                    continue
                }

                if !backedUpNotes.contains(candidate.noteURL) {
                    try scanner.backUpMetadata(for: candidate.noteURL, to: backupDirectory)
                    backedUpNotes.insert(candidate.noteURL)
                }

                let existing = attachments[index]
                attachments[index] = NoteAttachment(
                    id: existing.id,
                    url: existing.url,
                    type: existing.type,
                    extractedText: text,
                    extractionProvider: engineID.rawValue,
                    extractionModel: selectedModel
                )
                await attachmentRepository.upsertAttachments(
                    for: candidate.noteURL,
                    attachments: attachments
                )
                succeeded += 1
                if trimmed.isEmpty {
                    print("  Saved: no speech detected")
                } else {
                    print("  Saved: \(text.count) characters")
                }

            case .failure(let reason, let underlying):
                failed += 1
                let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
                print("  Failed: \(reason)\(detail)")
                if let urlError = underlying as? URLError,
                   urlError.code == .notConnectedToInternet
                {
                    pausedForOfflineNetwork = true
                    print("  Network is offline; pausing the resumable backfill.")
                    break candidateLoop
                }
            }
        }

        print("Backfill complete: succeeded=\(succeeded) failed=\(failed)")
        if pausedForOfflineNetwork {
            print("Backfill paused because the network is offline; rerun the same command to resume.")
        }
        print("Metadata backups: \(backupDirectory.path)")
        if failed > 0 { throw ExitCode.failure }
    }
}

private struct EvernoteAudioAttachmentCandidate {
    let noteURL: URL
    let attachmentID: UUID
    let attachmentURL: URL
}

private struct EvernoteAudioAttachmentScan {
    var evernoteNotes = 0
    var audioAttachments = 0
    var alreadyTranscribed = 0
    var missingFiles = 0
    var candidates: [EvernoteAudioAttachmentCandidate] = []
}

private struct EvernoteAudioAnalysisCandidate {
    let noteURL: URL
    let transcriptHash: String
    var contextChars = 0
}

private struct EvernoteAudioAnalysisScan {
    var evernoteNotes = 0
    var notesWithAudioTranscripts = 0
    var noSpeechOnlyNotes = 0
    var alreadyAnalyzed = 0
    var missingNoteFiles = 0
    var candidates: [EvernoteAudioAnalysisCandidate] = []
}

private struct EvernoteAudioAttachmentScanner {
    private let fileManager = FileManager.default
    private let metadataSuffix = ".meta.json"

    func scan(limit: Int?) throws -> EvernoteAudioAttachmentScan {
        let recordings = FileStore.recordingsDirectory()
        let files = try fileManager.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var result = EvernoteAudioAttachmentScan()

        for metadataURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where metadataURL.lastPathComponent.hasSuffix(metadataSuffix) {
            guard let data = try? Data(contentsOf: metadataURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["importSource"] as? String == "Evernote"
            else { continue }

            result.evernoteNotes += 1
            let noteName = String(metadataURL.lastPathComponent.dropLast(metadataSuffix.count))
            // Evernote imports are text notes; FileStore sidecars use the recording's
            // basename (`note.meta.json`), not its full filename (`note.txt.meta.json`).
            let noteURL = recordings.appendingPathComponent(noteName + ".txt")
            let attachments = root["attachments"] as? [[String: Any]] ?? []

            for attachment in attachments {
                guard let rawURL = attachment["url"] as? String,
                      let attachmentURL = resolveAttachmentURL(rawURL),
                      FileStore.isAudioFile(attachmentURL)
                else { continue }
                result.audioAttachments += 1

                let existingText = (attachment["extractedText"] as? String
                    ?? attachment["ocrText"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if existingText?.isEmpty == false {
                    result.alreadyTranscribed += 1
                    continue
                }
                guard fileManager.fileExists(atPath: attachmentURL.path) else {
                    result.missingFiles += 1
                    continue
                }
                guard let rawID = attachment["id"] as? String,
                      let attachmentID = UUID(uuidString: rawID)
                else { continue }

                if limit == nil || result.candidates.count < limit! {
                    result.candidates.append(EvernoteAudioAttachmentCandidate(
                        noteURL: noteURL,
                        attachmentID: attachmentID,
                        attachmentURL: attachmentURL
                    ))
                }
            }
        }
        return result
    }

    /// `includeOCR`: notes with photo/PDF text (`ocr-evernote`); the hash
    /// covers audio and OCR text and is stamped under `evernoteAttachments`.
    func scanForAnalysis(limit: Int?, includeOCR: Bool = false) throws -> EvernoteAudioAnalysisScan {
        let recordings = FileStore.recordingsDirectory()
        let files = try fileManager.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var result = EvernoteAudioAnalysisScan()

        for metadataURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where metadataURL.lastPathComponent.hasSuffix(metadataSuffix) {
            guard let data = try? Data(contentsOf: metadataURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["importSource"] as? String == "Evernote"
            else { continue }

            result.evernoteNotes += 1
            let ocrTexts = NoteAttachmentMedia.items(in: root).filter { !$0.isAudio && $0.text != nil }
            if includeOCR, ocrTexts.isEmpty { continue }
            let audioTranscripts: [(id: String, text: String)] =
                (root["attachments"] as? [[String: Any]] ?? []).compactMap { attachment in
                    guard let rawURL = attachment["url"] as? String,
                          let attachmentURL = resolveAttachmentURL(rawURL),
                          includeOCR || FileStore.isAudioFile(attachmentURL),
                          let text = (attachment["extractedText"] as? String
                            ?? attachment["ocrText"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty
                    else { return nil }
                    return (attachment["id"] as? String ?? rawURL, text)
                }
            guard !audioTranscripts.isEmpty else { continue }
            result.notesWithAudioTranscripts += 1

            let meaningful = audioTranscripts.filter {
                $0.text != TranscriptionSupport.noSpeechSentinel
            }
            guard !meaningful.isEmpty else {
                result.noSpeechOnlyNotes += 1
                continue
            }

            let hashInput = meaningful
                .sorted { $0.id < $1.id }
                .map { "\($0.id)\u{1f}\($0.text)" }
                .joined(separator: "\u{1e}")
            let digest = SHA256.hash(data: Data(hashInput.utf8))
            let transcriptHash = digest.map { String(format: "%02x", $0) }.joined()
            let storedHash = (((root["analysisBackfills"] as? [String: Any])?[includeOCR ? "evernoteAttachments" : "evernoteAudio"]
                as? [String: Any])?["transcriptHash"] as? String)
            if storedHash == transcriptHash {
                result.alreadyAnalyzed += 1
                continue
            }

            let noteName = String(metadataURL.lastPathComponent.dropLast(metadataSuffix.count))
            let noteURL = recordings.appendingPathComponent(noteName + ".txt")
            guard fileManager.fileExists(atPath: noteURL.path) else {
                result.missingNoteFiles += 1
                continue
            }
            if limit == nil || result.candidates.count < limit! {
                result.candidates.append(EvernoteAudioAnalysisCandidate(
                    noteURL: noteURL,
                    transcriptHash: transcriptHash,
                    contextChars: meaningful.reduce(0) { $0 + $1.text.count }
                ))
            }
        }
        return result
    }

    func makeBackupDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let directory = FileStore.recordingsDirectory()
            .appendingPathComponent("_evernote_audio_transcription_backup", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func makeAnalysisBackupDirectory() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let directory = FileStore.recordingsDirectory()
            .appendingPathComponent("_evernote_audio_analysis_backup", isDirectory: true)
            .appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func backUpMetadata(for noteURL: URL, to directory: URL) throws {
        let source = FileStore.metadataURL(forRecordingURL: noteURL)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    func restoreMetadata(for noteURL: URL, from directory: URL) throws {
        let destination = FileStore.metadataURL(forRecordingURL: noteURL)
        let backup = directory.appendingPathComponent(destination.lastPathComponent)
        let data = try Data(contentsOf: backup)
        try data.write(to: destination, options: .atomic)
    }

    private func resolveAttachmentURL(_ raw: String) -> URL? {
        NoteAttachmentMedia.resolve(raw)
    }
}

/// Reads the text in the photos and PDFs attached to Evernote notes, on the
/// Mac (Vision OCR, PDFKit text with OCR of scanned pages), so a note whose
/// content is a picture of a receipt, a whiteboard or a page becomes
/// searchable and readable by agents. Nothing leaves the device, so it also
/// runs in private mode. Writes go to the attachment entry in the note's
/// sidecar (`NoteAttachmentMedia.setText`); a picture without writing is
/// stored with an empty text, so a rerun does not read it again. The note is
/// not re-analyzed — that is a model call per note and a separate decision.
struct AttachmentsOCREvernote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ocr-evernote",
        abstract: "Read text from Evernote photo and PDF attachments on-device (dry-run by default)"
    )

    @Flag(name: .long, help: "Persist the recognized text; without this flag only report candidates")
    var apply: Bool = false

    @Option(name: .long, help: "Process at most this many eligible attachments")
    var limit: Int?

    @Option(name: .long, help: "OCR at most this many pages of a scanned PDF")
    var maxPDFPages: Int = 50

    @Flag(name: .long, help: "Read again attachments that already have text")
    var redo: Bool = false

    @Flag(name: .long, help: "Read again attachments whose previous extraction stored empty text")
    var redoEmpty: Bool = false

    func run() async throws {
        if let limit, limit < 1 { throw ValidationError("--limit must be greater than zero") }
        let scan = try Self.scan(redo: redo, redoEmpty: redoEmpty)
        let candidates = limit.map { Array(scan.candidates.prefix($0)) } ?? scan.candidates
        print("Evernote attachment OCR\(apply ? " [apply]" : " [dry-run]")")
        print("Evernote notes: \(scan.evernoteNotes)")
        print("Images: \(scan.images)  PDFs: \(scan.pdfs)")
        print("Already read: \(scan.alreadyRead)")
        print("Missing files: \(scan.missingFiles)")
        print("Not readable (svg, documents, other): \(scan.unsupported)")
        print("Eligible: \(scan.candidates.count)\(limit.map { " (this run: \(min($0, scan.candidates.count)))" } ?? "")")

        guard apply, !candidates.isEmpty else {
            if !apply { print("Run again with --apply to read these files.") }
            return
        }

        let importer = DocumentImporter(ocrEngine: .vision)
        var withText = 0, empty = 0, failed = 0, chars = 0
        let started = Date()
        for (offset, candidate) in candidates.enumerated() {
            let name = candidate.item.url.lastPathComponent
            do {
                let text: String
                let provider: String
                let model: String?
                if candidate.item.isPDF {
                    let result = try await importer.extractText(
                        from: candidate.item.url, maxOCRPages: maxPDFPages, generatesPreview: false)
                    text = result.text
                    provider = result.provider
                    model = result.model
                } else if Self.isTooSmallToRead(candidate.item.url) {
                    // Tracking pixels and spacers (2×2 GIFs): Vision refuses them.
                    text = ""
                    provider = TextExtractionProvider.vision
                    model = "too-small"
                } else {
                    text = try await importer.extractTextFromImage(at: candidate.item.url)
                    provider = TextExtractionProvider.vision
                    model = "VNRecognizeText"
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let written = try NoteAttachmentMedia.setText(
                    trimmed, provider: provider, model: model,
                    attachmentID: candidate.item.id, ofNote: candidate.noteURL, emptyIsNoSpeech: false)
                switch written {
                case .attachmentMissing:
                    failed += 1
                    print("[\(offset + 1)/\(candidates.count)] \(name): attachment no longer listed")
                case .keptExisting, .written:
                    if trimmed.isEmpty { empty += 1 } else { withText += 1; chars += trimmed.count }
                }
            } catch {
                failed += 1
                print("[\(offset + 1)/\(candidates.count)] \(name): FAILED \(error.localizedDescription)")
            }
            if (offset + 1) % 100 == 0 || offset + 1 == candidates.count {
                let elapsed = Int(Date().timeIntervalSince(started))
                print("[\(offset + 1)/\(candidates.count)] text=\(withText) empty=\(empty) failed=\(failed) chars=\(chars) \(elapsed)s")
            }
        }
        print("OCR complete: with text=\(withText) no text=\(empty) failed=\(failed)")
        if failed > 0 { throw ExitCode.failure }
    }

    /// Under 8 px on a side there is no text to read.
    static func isTooSmallToRead(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return min(width, height) < 8
    }

    struct Candidate {
        let noteURL: URL
        let item: NoteAttachmentMedia.Item
    }

    struct Scan {
        var evernoteNotes = 0
        var images = 0
        var pdfs = 0
        var alreadyRead = 0
        var missingFiles = 0
        var unsupported = 0
        var candidates: [Candidate] = []
    }

    /// Read-only pass over the Evernote sidecars in the recordings directory.
    static func scan(
        redo: Bool,
        redoEmpty: Bool = false,
        recordings: URL = FileStore.recordingsDirectory()
    ) throws -> Scan {
        let suffix = ".meta.json"
        let files = try FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var result = Scan()
        for metadataURL in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where metadataURL.lastPathComponent.hasSuffix(suffix) {
            guard let data = try? Data(contentsOf: metadataURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["importSource"] as? String == "Evernote"
            else { continue }
            result.evernoteNotes += 1
            // Evernote notes are `.txt`; the sidecar is named by the basename.
            let noteURL = recordings.appendingPathComponent(
                String(metadataURL.lastPathComponent.dropLast(suffix.count)) + ".txt")
            for item in NoteAttachmentMedia.items(in: root) where !item.isAudio {
                guard item.isImage || item.isPDF else { result.unsupported += 1; continue }
                if item.isImage { result.images += 1 } else { result.pdfs += 1 }
                let shouldRetryEmpty = redoEmpty && !item.hasMeaningfulText
                if item.wasExtracted, !redo, !shouldRetryEmpty { result.alreadyRead += 1; continue }
                guard FileManager.default.fileExists(atPath: item.url.path) else {
                    result.missingFiles += 1
                    continue
                }
                result.candidates.append(Candidate(noteURL: noteURL, item: item))
            }
        }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct AttachmentsAudit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Audit attachment references and OCR coverage"
    )

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Exit non-zero when findings are present")
    var strict: Bool = false

    func run() async throws {
        let service = MetadataAuditService()
        let report = await service.auditAttachments()

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let payload = String(data: data, encoding: .utf8) {
                print(payload)
            }
        } else {
            print("Attachment audit complete.")
            print("Scanned files: \(report.scannedFiles)")
            print("Entries with findings: \(report.entriesWithFindings)")
            print("Invalid URL: \(report.invalidURL)")
            print("Missing files: \(report.missingFiles)")
            print("Missing OCR: \(report.missingOCR)")

            if !report.entries.isEmpty {
                print("\nFindings:")
                for entry in report.entries.prefix(20) {
                    print("- \(entry.file): total=\(entry.total), invalidURL=\(entry.invalidURL), missingFiles=\(entry.missingFiles), missingOCR=\(entry.missingOCR)")
                }
                if report.entries.count > 20 {
                    print("- ... and \(report.entries.count - 20) more")
                }
            }
        }

        if strict && (report.invalidURL > 0 || report.missingFiles > 0 || report.missingOCR > 0) {
            throw ExitCode(1)
        }
    }
}
