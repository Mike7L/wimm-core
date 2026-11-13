import Foundation
import Darwin
import WimmDomain
import WimmInfrastructure

// MARK: - Entry Point
// AppContainer  → Container/AppContainer.swift
// MockAdapters  → Container/MockAdapters.swift
// Commands      → Commands/NotesCommands.swift, RecordCommands.swift, QueueCommands.swift, AdvancedNotesCommands.swift

public enum WimmTUIRuntime {
    public static func main() async {
        loadEnvironmentFilesIfPresent()
        var cliArgs = Array(CommandLine.arguments.dropFirst())
        cliArgs = configureTranscriberEngineIfNeeded(args: cliArgs)

        let container = AppContainer()
        var autoProcessAfterRecord = true

        if !cliArgs.isEmpty {
            do {
                _ = try await execute(
                    args: cliArgs,
                    container: container,
                    autoProcessAfterRecord: &autoProcessAfterRecord
                )
            } catch {
                print("Error: \(error)")
                exit(1)
            }
            return
        }

        print("Welcome to WIMM (Where Is My Mind) TUI")
        print("Type 'help' for commands.")

        while true {
            print("> ", terminator: "")
            guard let input = readLine() else { break }
            let args = input.split(separator: " ").map(String.init)
            guard !args.isEmpty else { continue }
            do {
                let shouldExit = try await execute(
                    args: args,
                    container: container,
                    autoProcessAfterRecord: &autoProcessAfterRecord
                )
                if shouldExit { return }
            } catch {
                print("Error: \(error)")
            }
        }
    }

    /// One-shot entry for in-process embedding (WimmCLI). Mirrors the
    /// subprocess behavior the old WimmTUIRuntime provided: env files are
    /// loaded and the transcriber engine flag is applied before dispatch.
    public static func runOnce(_ args: [String]) async throws {
        loadEnvironmentFilesIfPresent()
        let cliArgs = configureTranscriberEngineIfNeeded(args: args)
        let container = AppContainer()
        var autoProcessAfterRecord = true
        _ = try await execute(
            args: cliArgs,
            container: container,
            autoProcessAfterRecord: &autoProcessAfterRecord
        )
    }

    // MARK: - Command Dispatch

    private static func execute(
        args: [String],
        container: AppContainer,
        autoProcessAfterRecord: inout Bool
    ) async throws -> Bool {
        let command = args[0]
        let rest = Array(args.dropFirst())

        switch command {
        case "help":
            printHelp()
        case "list":
            try await runList(args: rest, container: container)
        case "read":
            try await runRead(args: rest, container: container)
        case "search":
            try await runSearch(args: rest, container: container)
        case "record":
            try await runRecord(args: rest, container: container, autoProcessAfterRecord: &autoProcessAfterRecord)
        case "process":
            try await runProcess(args: rest, container: container)
        case "capture":
            try await runCapture(args: rest, container: container)
        case "hud":
            return try await runHUD(container: container, autoProcessAfterRecord: &autoProcessAfterRecord)
        case "queue":
            try await runQueue(args: rest, container: container)
        case "notes":
            try await runNotes(args: rest, container: container)
        case "delete":
            try await runDelete(args: rest, container: container)
        case "stats":
            try await runStats(args: rest, container: container)
        case "transcript":
            try await runTranscript(args: rest, container: container)
        case "export":
            try await runExport(args: rest, container: container)
        case "import":
            try await runImport(args: rest, container: container)
        case "clean":
            try await runClean(args: rest, container: container)
        case "doctor":
            try await runDoctor(args: rest, container: container)
        case "interactive":
            return try await runInteractive(container: container, autoProcessAfterRecord: &autoProcessAfterRecord)
        case "exit":
            print("Bye!")
            return true
        default:
            print("Unknown command: \(command). Type 'help' for available commands.")
        }
        return false
    }

    private static func runInteractive(
        container: AppContainer,
        autoProcessAfterRecord: inout Bool
    ) async throws -> Bool {
        print("Entering WIMM Interactive Mode. Type 'exit' to quit.")
        print("Commands: list [limit], view <id-prefix>, search <query>, like <id-prefix>, delete <id-prefix>, help, exit")

        while true {
            print("> ", terminator: "")
            guard let line = readLine() else { return true }
            let parts = line.split(separator: " ").map(String.init)
            guard let command = parts.first else { continue }

            let mappedArgs: [String]
            switch command {
            case "view":
                guard parts.count > 1 else { print("Usage: view <id-prefix>"); continue }
                mappedArgs = ["read", parts[1]]
            case "search":
                guard parts.count > 1 else { print("Usage: search <query>"); continue }
                mappedArgs = ["search", "--text", parts.dropFirst().joined(separator: " ")]
            case "like":
                guard parts.count > 1 else { print("Usage: like <id-prefix>"); continue }
                mappedArgs = ["notes", "like", parts[1]]
            case "reset":
                mappedArgs = ["list", "--limit", "10"]
            case "interactive":
                print("Already in interactive mode.")
                continue
            default:
                mappedArgs = parts
            }

            let shouldExit = try await execute(
                args: mappedArgs,
                container: container,
                autoProcessAfterRecord: &autoProcessAfterRecord
            )
            if shouldExit { return true }
        }
    }

    // MARK: - Help

    static func loadEnvironmentFilesIfPresent(
        startingAt directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    ) {
        for fileURL in discoverEnvironmentFiles(startingAt: directory) {
            _ = try? loadEnvironmentFile(fileURL, overrideExisting: false)
        }
    }

    static func discoverEnvironmentFiles(startingAt directory: URL) -> [URL] {
        var current = directory.resolvingSymlinksInPath()
        let fm = FileManager.default

        while true {
            let env = current.appendingPathComponent(".env", isDirectory: false)
            let envLocal = current.appendingPathComponent(".env.local", isDirectory: false)
            var files: [URL] = []
            if fm.fileExists(atPath: env.path) {
                files.append(env)
            }
            if fm.fileExists(atPath: envLocal.path) {
                files.append(envLocal)
            }
            if !files.isEmpty {
                return files
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return []
            }
            current = parent
        }
    }

    @discardableResult
    static func loadEnvironmentFile(_ fileURL: URL, overrideExisting: Bool) throws -> [String] {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        var loaded: [String] = []

        for (key, value) in parseEnvironmentAssignments(contents) {
            if !overrideExisting, ProcessInfo.processInfo.environment[key] != nil {
                continue
            }
            setenv(key, value, 1)
            loaded.append(key)
        }

        return loaded
    }

    static func parseEnvironmentAssignments(_ contents: String) -> [(String, String)] {
        contents
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

                let normalized: String
                if line.hasPrefix("export ") {
                    normalized = String(line.dropFirst("export ".count))
                } else {
                    normalized = line
                }

                guard let equalIndex = normalized.firstIndex(of: "=") else { return nil }
                let key = normalized[..<equalIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }

                var value = normalized[normalized.index(after: equalIndex)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value.count >= 2 {
                    let first = value.first
                    let last = value.last
                    if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                        value = String(value.dropFirst().dropLast())
                    }
                }

                return (key, value)
            }
    }

    private static func configureTranscriberEngineIfNeeded(args: [String]) -> [String] {
        guard let command = args.first else { return args }
        guard command == "process" || command == "record" || command == "capture" || command == "hud" else {
            return args
        }
        let rest = Array(args.dropFirst())
        guard let engine = ArgParser(rest).string(anyOf: "--engine", "-e")?.lowercased() else {
            return args
        }

        let resolved: String
        switch engine {
        case "native", "gemini", "gemini-live", "openrouter", "whisper", "mock":
            resolved = engine
        default:
            print("Warning: --engine \(engine) is unsupported. Allowed: native|gemini|gemini-live|openrouter|whisper|mock. Using native.")
            resolved = "native"
        }

        setenv("WIMM_TRANSCRIBER", resolved, 1)
        return args
    }

    private static func printHelp() {
        print("""
        Available commands:
          list [--limit N] [--json]
          read <id>
          search [--text <q>] [--tag <t>] [--project <p>] [--status <s>] [--limit N] [--json]
          record [--engine native|gemini|gemini-live|openrouter|whisper|mock] [--auto-process on|off]
          process [<file>] [--engine native|gemini|gemini-live|openrouter|whisper|mock] [--transcribe always|if-missing|skip] [--dry-run]
          capture [--engine native|gemini|gemini-live|openrouter|whisper|mock] [--dry-run]
          hud [--engine native|gemini|gemini-live|openrouter|whisper|mock]
          queue process [--limit N] [--dry-run]
          queue status [--details]
          queue retry [--all|--id <prefix>] [--dry-run]
          queue report [--format md|csv] [--output <path>]
          notes query [--query <q>] [--insights] [--drafts] [--artifacts] [--liked]
                      [--unassigned] [--unprocessed] [--project <id>] [--limit N] [--json]
          notes select --id <uuid> [--selected <ids>] [--additive] [--json]
          notes like <id-prefix>
          delete <id-prefix>
          stats [--json]
          transcript <id_prefix|audio_filename>
          export [--output <dir>] [-o <dir>] [--json] [--limit N]
          import <file1> [file2...] [--dry-run]   (audio + Evernote .enex exports)
          clean [--force]
          doctor
          exit
        """)
    }
}
