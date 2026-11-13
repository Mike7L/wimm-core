import Foundation
import WimmDomain
import WimmInfrastructure

// MARK: - stats

extension WimmTUIRuntime {

    static func runStats(args: [String], container: AppContainer) async throws {
        let p = ArgParser(args)
        let json = p.flag("--json")

        let notes = try await container.listNotes.execute()
        var completed = 0
        var pending = 0
        var failed = 0

        for note in notes {
            switch note.status {
            case .completed:        completed += 1
            case .pendingAnalysis:  pending += 1
            case .failed:           failed += 1
            }
        }

        if json {
            let obj: [String: Any] = [
                "total":     notes.count,
                "completed": completed,
                "pending":   pending,
                "failed":    failed,
                "root":      container.storageRoot.path
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("WIMM Statistics")
            print("  Root:      \(container.storageRoot.path)")
            print("  Total:     \(notes.count)")
            print("  Completed: \(completed)")
            print("  Pending:   \(pending)")
            print("  Failed:    \(failed)")
        }
    }
}

// MARK: - transcript

extension WimmTUIRuntime {

    static func runTranscript(args: [String], container: AppContainer) async throws {
        guard let prefix = args.first else {
            print("Usage: transcript <id_prefix|audio_filename>")
            return
        }

        // Try by ID prefix first, then by audio filename.
        let note: CapturedNote?
        if let found = try await container.readNote.execute(idPrefix: prefix) {
            note = found
        } else if let found = try await container.storage.loadNote(matchingAudioPath: prefix) {
            note = found
        } else {
            note = nil
        }

        guard let n = note else {
            print("Note not found: \(prefix)")
            return
        }

        print("ID:      \(n.id)")
        print("Created: \(n.createdAt)")
        print("Status:  \(n.status)")
        if let title = n.title ?? n.card?.title {
            print("Title:   \(title)")
        }
        if let audio = n.audioPath {
            print("Audio:   \(audio)")
        }
        print("")
        if n.text.isEmpty {
            print("(No transcript)")
        } else {
            print(n.text)
        }
        if let card = n.card, !card.summary.isEmpty {
            print("")
            print("Summary: \(card.summary)")
        }
    }
}

// MARK: - export

extension WimmTUIRuntime {

    static func runExport(args: [String], container: AppContainer) async throws {
        let p = ArgParser(args)
        let outputPath = p.string("--output") ?? p.string("-o")
        let jsonMode = p.flag("--json")
        let limitArg = p.int("--limit")

        let notes = try await container.listNotes.execute()
        let limited = limitArg.map { Array(notes.prefix(max(0, $0))) } ?? notes

        // Resolve output directory.
        let fm = FileManager.default
        let outDir: URL
        if let path = outputPath {
            outDir = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let timestamp = ISO8601.now
                .replacingOccurrences(of: ":", with: "-")
            outDir = fm.temporaryDirectory.appendingPathComponent("wimm_export_\(timestamp)", isDirectory: true)
        }
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        if jsonMode {
            let encoder = WimmTUIRuntime.prettyJSONEncoder
            let data = try encoder.encode(limited)
            let file = outDir.appendingPathComponent("notes.json")
            try data.write(to: file, options: .atomic)
            print("Exported \(limited.count) note(s) → \(file.path)")
        } else {
            // Plain markdown chronicle.
            var lines: [String] = ["# WIMM Export", ""]
            for note in limited {
                let title = note.card?.title ?? note.title ?? "Untitled"
                let date = note.createdAt
                lines.append("## \(title)")
                lines.append("- Date: \(date)")
                lines.append("- Status: \(note.status)")
                if let tags = note.card?.tags, !tags.isEmpty {
                    lines.append("- Tags: \(tags.joined(separator: ", "))")
                }
                if !note.text.isEmpty {
                    lines.append("")
                    lines.append(note.text)
                }
                lines.append("")
                lines.append("---")
                lines.append("")
            }
            let markdown = lines.joined(separator: "\n")
            let file = outDir.appendingPathComponent("notes.md")
            try markdown.write(to: file, atomically: true, encoding: .utf8)
            print("Exported \(limited.count) note(s) → \(file.path)")
        }
    }
}

// MARK: - import

extension WimmTUIRuntime {

    static func runImport(args: [String], container: AppContainer) async throws {
        let p = ArgParser(args)
        let dryRun = p.flag("--dry-run")
        let paths = args.filter { !$0.hasPrefix("--") }

        guard !paths.isEmpty else {
            print("Usage: import <file1> [file2...] [--dry-run]")
            return
        }

        // Route Evernote exports through the dedicated streaming importer.
        let enexURLs = paths
            .map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "enex" }
        if !enexURLs.isEmpty {
            try await runEvernoteImport(urls: enexURLs, dryRun: dryRun, container: container)
        }

        let supportedExtensions: Set<String> = ["m4a", "caf", "wav", "mp3", "mp4"]
        var imported = 0
        var skipped = 0
        var failed = 0

        for path in paths {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            if ext == "enex" { continue }  // handled above
            guard supportedExtensions.contains(ext) else {
                print("Skipped (unsupported type): \(url.lastPathComponent)")
                skipped += 1
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("Skipped (not found): \(path)")
                skipped += 1
                continue
            }

            if dryRun {
                print("[dry-run] Would import: \(url.lastPathComponent)")
                imported += 1
                continue
            }

            do {
                let data = try Data(contentsOf: url)
                let note = try await container.storage.saveRecording(
                    data: data,
                    fileName: url.lastPathComponent,
                    initialText: ""
                )
                print("Imported: \(url.lastPathComponent) → [\(note.shortID)]")
                imported += 1
            } catch {
                print("Failed: \(url.lastPathComponent) — \(error)")
                failed += 1
            }
        }

        print("")
        print("Summary: imported=\(imported)  skipped=\(skipped)  failed=\(failed)  dry-run=\(dryRun)")
    }

    static func runEvernoteImport(urls: [URL], dryRun: Bool, container: AppContainer) async throws {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        for missing in urls where !existing.contains(missing) {
            print("Skipped (not found): \(missing.path)")
        }
        guard !existing.isEmpty else { return }

        print("Evernote import: \(existing.count) file(s)\(dryRun ? " [dry-run]" : "")")

        let importer = EvernoteImporter(storageRoot: container.storageRoot)
        let summary = try await importer.importENEX(at: existing, dryRun: dryRun) { index, title in
            let short = title.count > 50 ? String(title.prefix(47)) + "..." : title
            print("  [\(index)] \(short)")
        }

        print("")
        print(
            "Evernote summary: found=\(summary.found)  imported=\(summary.imported)  "
                + "skipped=\(summary.skipped)  attachments=\(summary.attachments)  "
                + "failed=\(summary.failed)  dry-run=\(dryRun)")
    }
}

// MARK: - clean

extension WimmTUIRuntime {

    static func runClean(args: [String], container: AppContainer) async throws {
        let p = ArgParser(args)
        let force = p.flag("--force")

        let notes = try await container.listNotes.execute()
        let fm = FileManager.default
        var ghosts: [CapturedNote] = []

        for note in notes {
            guard let audioPath = note.audioPath else {
                // CapturedNote with no audio at all — treat as ghost only if text is empty too.
                if note.text.isEmpty {
                    ghosts.append(note)
                }
                continue
            }
            let fullURL = container.storageRoot.appendingPathComponent(audioPath)
            if !fm.fileExists(atPath: fullURL.path) {
                ghosts.append(note)
            }
        }

        if ghosts.isEmpty {
            print("Clean: no orphan notes found.")
            return
        }

        print("Found \(ghosts.count) orphan note(s) (missing audio):")
        for ghost in ghosts {
            let title = ghost.card?.title ?? ghost.title ?? "(no title)"
            let audio = ghost.audioPath ?? "(no audio)"
            print("  [\(ghost.shortID)] \(ghost.createdAt)  \(title)  audio=\(audio)")
        }

        if force {
            var deleted = 0
            var deleteFailed = 0
            for ghost in ghosts {
                do {
                    try await container.storage.deleteNote(id: ghost.id)
                    print("Deleted: [\(ghost.shortID)]")
                    deleted += 1
                } catch {
                    print("Failed to delete [\(ghost.shortID)]: \(error)")
                    deleteFailed += 1
                }
            }
            print("Done: deleted=\(deleted)  failed=\(deleteFailed)")
        } else {
            print("")
            print("Run with --force to delete.")
        }
    }
}

// MARK: - doctor

extension WimmTUIRuntime {

    static func runDoctor(args: [String], container: AppContainer) async throws {
        let root = container.storageRoot
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment

        print("WIMM Doctor")
        print("==============")

        // 1. Storage root
        print("\nStorage:")
        print("  Root: \(root.path)")
        let rootExists = fm.fileExists(atPath: root.path)
        print("  Exists:       \(rootExists ? "✓" : "✗ MISSING")")

        // 2. Write access
        let testFile = root.appendingPathComponent(".doctor_write_test")
        do {
            try "ok".write(to: testFile, atomically: true, encoding: .utf8)
            try fm.removeItem(at: testFile)
            print("  Write access: ✓")
        } catch {
            print("  Write access: ✗ FAILED — \(error.localizedDescription)")
        }

        // 3. API keys
        print("\nAPI Keys:")
        let geminiKey = env["GEMINI_API_KEY"] ?? ""
        if geminiKey.isEmpty {
            print("  GEMINI_API_KEY: ✗ missing (analysis will use mock)")
        } else {
            print("  GEMINI_API_KEY: ✓ (length=\(geminiKey.count))")
        }

        // 3.1 Transcription runtime
        let transcriptionEngine = TranscriptionEngine.fromEnvironment(env)
        print("\nTranscription:")
        print("  Engine: \(transcriptionEngine.rawValue)")
        switch transcriptionEngine {
        case .native:
            print("  Mode: real-time native speech recognition")
        case .gemini:
            let ok = !(env["GEMINI_API_KEY"] ?? "").isEmpty
            print("  GEMINI_API_KEY: \(ok ? "✓" : "✗ missing (will fallback to mock)")")
            print("  Mode: hybrid native live capture + Gemini final/file transcription")
        case .geminiLive:
            let ok = !(env["GEMINI_API_KEY"] ?? "").isEmpty
            print("  GEMINI_API_KEY: \(ok ? "✓" : "✗ missing (will fallback to mock)")")
            print("  Mode: Gemini Live WebSocket streaming transcription")
        case .openrouter:
            let ok = !(env["OPENROUTER_API_KEY"] ?? "").isEmpty
            print("  OPENROUTER_API_KEY: \(ok ? "✓" : "✗ missing (will fallback to mock)")")
        case .whisper:
            print("  Mode: local WhisperKit transcription")
        case .mock:
            print("  Mode: mock (not real transcription)")
        }

        // 4. Notes integrity check
        print("\nNotes:")
        do {
            let notes = try await container.listNotes.execute()
            var completed = 0
            var pending = 0
            var failed = 0
            var noAudio = 0
            var missingAudio = 0

            for note in notes {
                switch note.status {
                case .completed:       completed += 1
                case .pendingAnalysis: pending += 1
                case .failed:          failed += 1
                }
                if let audioPath = note.audioPath {
                    let full = root.appendingPathComponent(audioPath)
                    if !fm.fileExists(atPath: full.path) { missingAudio += 1 }
                } else {
                    noAudio += 1
                }
            }

            print("  Total:         \(notes.count)")
            print("  Completed:     \(completed)")
            print("  Pending:       \(pending)")
            print("  Failed:        \(failed)")
            if noAudio > 0    { print("  No audio:      \(noAudio)  ← consider clean") }
            if missingAudio > 0 { print("  Missing audio: \(missingAudio)  ← run clean --force") }
            if failed == 0 && missingAudio == 0 {
                print("\n✓ All checks passed.")
            } else {
                print("\n⚠ Issues found — see above.")
            }
        } catch {
            print("  Error loading notes: \(error)")
        }
    }
}
