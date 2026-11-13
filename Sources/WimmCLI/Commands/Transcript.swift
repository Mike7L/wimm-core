import ArgumentParser
import Foundation
import WimmInfrastructure
import WimmDomain
import WimmTranscription

struct Transcript: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcript tools",
        subcommands: [TranscriptRebuild.self, TranscriptRetry.self, TranscriptRetranscribe.self, TranscriptClearNoSpeech.self, TranscriptDrainQueue.self]
    )
}

struct TranscriptRetry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retry",
        abstract: "Force cloud retranscription of one recording"
    )

    @Argument(help: "Path to the audio recording")
    var path: String

    @Option(name: .long, help: "Engine: gemini or openrouter")
    var engine: String = "gemini"

    @Option(name: .long, help: "Override transcription model")
    var model: String?

    @Option(name: .long, help: "Spoken language hint")
    var lang: String = "Auto"

    func run() async throws {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw ValidationError("File not found: \(file.path)")
        }
        guard let engineID = EngineID(rawValue: engine.lowercased()), engineID != .native else {
            throw ValidationError("Engine must be gemini or openrouter")
        }

        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Config.transcribeModel
        let service = TranscriptionService(
            rotator: .shared,
            model: selectedModel,
            transport: .shared
        )
        print("Retranscribing \(file.lastPathComponent) via \(engineID.rawValue)/\(selectedModel)...")
        let result = await service.transcribe(
            file: file,
            engine: engineID,
            model: selectedModel,
            language: lang,
            progress: { progress, _, elapsed in
                if progress >= 0.999 {
                    print(String(format: "Cloud transcription completed in %.1fs", elapsed))
                }
            }
        )

        switch result {
        case .success(let text):
            print("Transcript saved (\(text.count) characters).")
            print(String(text.prefix(240)))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                print("No speech detected; analysis is not applicable.")
                return
            }
            print("Running note analysis...")
            _ = try await NoteProcessor.shared.reprocess(
                file: file,
                requestContext: [
                    "origin": "WimmCLI.TranscriptRetry",
                    "reason": "Analyze note after forced retranscription",
                ]
            )
            print("Analysis completed.")
        case .failure(let reason, let underlying):
            let detail = underlying.map { ": \($0.localizedDescription)" } ?? ""
            print("Transcription failed (\(reason))\(detail)")
            throw ExitCode.failure
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Works off the retranscriptions agents asked for over MCP
/// (`request_retranscription`), one at a time, then exits. The MCP server
/// starts it detached, so a long queue outlives the agent's session; a second
/// worker started meanwhile sees the lock and leaves. One process for the
/// whole queue also means Parakeet loads (and compiles) its model once.
struct TranscriptDrainQueue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drain-queue",
        abstract: "Run the retranscriptions requested over MCP (started by `wimm-cli mcp`)"
    )

    func run() async throws {
        let done = try await RetranscriptionWorker.drain(
            origin: "WimmCLI.TranscriptDrainQueue",
            defaultReason: "Analyze note after a retranscription an agent requested"
        ) { entry, outcome in
            let name = URL(fileURLWithPath: entry.file).lastPathComponent
            if let outcome {
                print("[\(ISO8601.now)] \(name): \(outcome.failed ? "FAILED " : "")\(outcome.summary)")
            } else {
                print("[\(ISO8601.now)] \(name) via \(entry.model)…")
            }
        }
        guard let done else {
            print("Another retranscription worker is running.")
            return
        }
        print("[\(ISO8601.now)] Queue empty after \(done) request(s).")
    }
}

/// Retranscribes one note found by id, the way `get_note` finds it. Dry-run
/// unless `--apply`; a cloud model in private mode is refused before any upload.
struct TranscriptRetranscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "retranscribe",
        abstract: "Retranscribe a note by id or file name (dry-run by default)"
    )

    @Argument(help: "Note id, an unambiguous prefix of it, or the note's file name")
    var note: String

    @Option(name: .long, help: "Hear model, e.g. parakeet:ultra or gemini-3-flash-preview (default: the Settings hear model)")
    var model: String?

    @Option(name: .long, help: "Spoken language hint")
    var lang: String = "Auto"

    @Flag(inversion: .prefixedNo, help: "Re-run the note analysis after a transcript with speech")
    var analyze: Bool = true

    @Flag(name: .long, help: "Run the transcription (default: report only)")
    var apply: Bool = false

    func run() async throws {
        let library = await LibraryRecallSource(buildMode: .inProcess).load()
        guard let found = NoteRecall.find(library, reference: note) else {
            throw ValidationError("No single note matches \"\(note)\".")
        }
        let noteFile = URL(fileURLWithPath: found.filePath)
        // A text note (Evernote) is retranscribed through its audio attachments.
        let targets: [(file: URL, attachmentID: UUID?, words: Int)]
        if found.kind == "audio" {
            targets = [(noteFile, nil, NoteRetranscription.storedWordCount(file: noteFile))]
        } else {
            targets = NoteAttachmentMedia.audio(ofNote: noteFile).map {
                ($0.url, $0.id, $0.hasMeaningfulText ? NoteRetranscription.wordCount($0.text ?? "") : 0)
            }
            guard !targets.isEmpty else {
                throw ValidationError("[\(found.id)] is not audio (\(found.kind)) and has no audio attachments — nothing to transcribe.")
            }
        }
        let selectedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? Config.transcribeModel

        print("retranscribe — \(apply ? "APPLY" : "DRY-RUN")")
        print("  note    [\(found.id)] \(noteFile.lastPathComponent)")
        print("  model   \(selectedModel)\(ParakeetModel.isParakeet(selectedModel) ? " (on-device)" : " (cloud)")")
        for target in targets {
            let label = target.attachmentID == nil ? "current" : "attachment \(target.file.lastPathComponent):"
            print("  \(label) \(target.words) words")
        }
        if let refusal = NoteRetranscription.privateModeRefusal(model: selectedModel) {
            print(refusal)
            throw ExitCode.failure
        }
        guard apply else {
            print("Nothing written; pass --apply to run it.")
            return
        }
        var anyFailed = false
        for (i, target) in targets.enumerated() {
            // Analyze once, after the last attachment, so the card sees them all.
            let outcome = await NoteRetranscription.run(
                file: target.file,
                model: selectedModel,
                language: lang,
                analyze: analyze && i == targets.count - 1,
                attachmentOf: target.attachmentID == nil ? nil : noteFile,
                attachmentID: target.attachmentID,
                requestContext: [
                    "origin": "WimmCLI.TranscriptRetranscribe",
                    "reason": "Analyze note after retranscription by id",
                ]
            )
            let prefix = target.attachmentID == nil ? "" : "\(target.file.lastPathComponent): "
            print("\(prefix)\(outcome.failed ? "FAILED " : "")\(outcome.summary)")
            anyFailed = anyFailed || outcome.failed
        }
        if anyFailed { throw ExitCode.failure }
    }
}

/// Clears a transcript a fresh retranscription confirmed as made up over
/// silence. `transcript retry` cannot do it: an empty result never replaces
/// earlier text (`recordRunSuccess`). Dry-run unless `--apply`.
struct TranscriptClearNoSpeech: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-no-speech",
        abstract: "Clear transcripts confirmed as made up over silence (dry-run by default)"
    )

    @Argument(help: "Audio recordings whose transcript to clear")
    var paths: [String]

    @Option(name: .long, help: "Reason stored in the sidecar")
    var reason: String = "confirmed_no_speech"

    @Flag(name: .long, help: "Write the change (default: report only)")
    var apply: Bool = false

    func run() async throws {
        print("clear-no-speech — \(apply ? "APPLY" : "DRY-RUN")")
        var cleared = 0, skipped = 0, missing = 0
        for path in paths {
            let file = URL(fileURLWithPath: path).standardizedFileURL
            let sidecar = FileStore.metadataURL(forRecordingURL: file)
            guard FileManager.default.fileExists(atPath: sidecar.path) else {
                print("  missing  \(file.lastPathComponent)")
                missing += 1
                continue
            }
            var outcome: HallucinatedTranscriptClearing.Outcome = .skippedAlreadyEmpty
            var preview = ""
            try FileStore.mutateSidecar(at: sidecar) { meta in
                preview = ((meta["transcription"] as? [String: Any])?["transcript"] as? String ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                outcome = HallucinatedTranscriptClearing.clear(&meta, reason: reason)
                if case .cleared = outcome { return apply }
                return false
            }
            switch outcome {
            case .cleared(let words):
                cleared += 1
                print("  clear    \(file.lastPathComponent)  (\(words) words) \"\(preview.prefix(80))\"")
            case .skippedUserEdited:
                skipped += 1
                print("  skip     \(file.lastPathComponent)  (card text edited by hand)")
            case .skippedAlreadyEmpty:
                skipped += 1
                print("  skip     \(file.lastPathComponent)  (already empty)")
            }
        }
        print("cleared=\(cleared)\(apply ? "" : " (dry-run)") skipped=\(skipped) missing=\(missing)")
    }
}

struct TranscriptRebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild",
        abstract: "Normalize and rewrite transcript metadata"
    )

    @Argument(help: "Path to a specific file to rebuild")
    var path: String?

    @Flag(name: .long, help: "Rebuild all recordings")
    var all: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Exit non-zero when any file fails")
    var strict: Bool = false

    func run() async throws {
        if (path == nil && !all) || (path != nil && all) {
            throw ValidationError("Specify either <path> or --all")
        }

        let service = MetadataAuditService()
        let report = await service.rebuildTranscripts(path: path, all: all)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            if let payload = String(data: data, encoding: .utf8) {
                print(payload)
            }
        } else {
            print("Transcript rebuild complete.")
            print("Total: \(report.total)")
            print("Rebuilt: \(report.rebuilt)")
            print("Skipped: \(report.skipped)")
            print("Failed: \(report.failed)")

            if !report.items.isEmpty {
                print("\nDetails:")
                for item in report.items.prefix(20) {
                    print("- \(item.file): \(item.status) - \(item.message)")
                }
                if report.items.count > 20 {
                    print("- ... and \(report.items.count - 20) more")
                }
            }
        }

        if strict && report.failed > 0 {
            throw ExitCode(1)
        }
    }
}
