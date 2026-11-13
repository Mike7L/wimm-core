import ArgumentParser
import Foundation
import WimmInfrastructure
import WimmSecretary

/// Wimm as the secretary's dispatcher (`docs/Secretary_Dispatcher.md`): hand
/// a task to an outside agent, then verify what it did. Dry run by default.
struct Secretary: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secretary",
        abstract: "Run the secretary (an outside agent) on a workspace document",
        subcommands: [BriefFiles.self, WarmLibrary.self, PrepareFiles.self, ReadFiles.self, ApplyFiles.self, SessionSnapshot.self, CodexPacket.self, GeminiPacket.self, GeminiReplay.self, GeminiBenchmark.self, ClaudePacket.self, TerraAPI.self, CommentsRun.self, PassRun.self, Registry.self, Hold.self, Reconcile.self, ReplayRun.self, RunLog.self, RunCheck.self]
    )

    struct BriefFiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "brief", abstract: "Return a complete lossless editor bundle for one read → one apply")
        @Argument var document: String
        @Option(name: .long, help: "Full source budget; 512 KB default (prepare defaults to 64 for conversation)") var packetKB = 512
        func run() async throws {
            guard let cli = SecretaryDispatcher.locateWimmCLI() else { throw SecretaryError.wimmCLIMissing }
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            let result = try await SecretaryPacketFiles.prepare(document: url, cli: cli, sourceKB: packetKB, editorBundle: true)
            print(String(decoding: result, as: UTF8.self))
        }
    }

    struct WarmLibrary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "warm", abstract: "Prewarm the local secretary library cache; no model, marks or packet")
        func run() async throws {
            guard let cli = SecretaryDispatcher.locateWimmCLI() else { throw SecretaryError.wimmCLIMissing }
            print(String(decoding: try await SecretaryPacketFiles.warm(cli: cli), as: UTF8.self))
        }
    }

    struct PrepareFiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "prepare", abstract: "Export a versioned source packet for the current editor; no model or agent is started")
        @Argument(help: "Workspace Markdown document") var document: String
        @Option(name: .long, help: "Source budget, 64–1024 KB; KB = 1000 bytes. 64 is one conversational portion; the rest stays in remaining") var packetKB = 64
        @Flag(name: .long, help: "Prepare a packet without processing comments; apply is limited to --dry-run") var packetOnly = false
        @Flag(name: .long, help: "Select only registry pending notes whose primary text has not been read, regardless of marks or dates") var unreadPending = false
        @Option(name: .long, help: "Budget for requested document context, 96–1024 KB; source budget is separate") var contextKB = 96
        @Option(name: .long, help: "Maximum complete sources per call (unread pending defaults to 32); remaining sources stay queued") var maxSources: Int?
        @Flag(name: .long, help: "With --unread-pending: re-offer unchanged unfinished or skipped sources; no marks are changed") var retryUnfinished = false
        @Option(name: .customLong("exclude-source-id"), help: "With --unread-pending: leave this exact source queued during this sweep; repeatable, no marks are changed") var excludedSourceIDs: [String] = []
        @Option(name: .customLong("source-id"), help: "With --packet-only: include this registry source in the dry sample. Repeat for each source.") var sourceIDs: [String] = []
        func run() async throws {
            guard let cli = SecretaryDispatcher.locateWimmCLI() else { throw SecretaryError.wimmCLIMissing }
            guard packetOnly || sourceIDs.isEmpty else { throw ValidationError("--source-id needs --packet-only.") }
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            let data = try await SecretaryPacketFiles.prepare(document: url, cli: cli, sourceKB: packetKB,
                                                              packetOnly: packetOnly, sampleSourceIDs: Set(sourceIDs), unreadPending: unreadPending, retryUnfinished: retryUnfinished, maxSources: maxSources ?? (unreadPending ? 32 : nil), excludedSourceIDs: Set(excludedSourceIDs), contextKB: contextKB)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct SessionSnapshot: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "snapshot", abstract: "Export a complete secretary session for analysis; no model calls or bookkeeping changes")
        @Argument var runID: String?
        @Option(name: .long, help: "Self-contained .json.lzfse checkpoint; usable without the shared archive database") var checkpoint: String?
        @Option(name: .long, help: "New JSON file; existing files are never overwritten") var output: String
        func run() async throws {
            guard (runID != nil) != (checkpoint != nil) else { throw ValidationError("Choose a run ID or --checkpoint.") }
            let destination = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
            let data: Data
            if let checkpoint {
                data = try SecretaryPacketFiles.checkpointSnapshot(file: URL(fileURLWithPath: (checkpoint as NSString).expandingTildeInPath))
            } else { data = try SecretaryPacketFiles.sessionSnapshot(runID: runID!) }
            try data.write(to: destination, options: .withoutOverwriting)
            let result = try JSONSerialization.data(withJSONObject: ["output": destination.path, "bytes": data.count], options: .sortedKeys)
            print(String(decoding: result, as: UTF8.self))
        }
    }

    struct ReadFiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "read", abstract: "Read a prepared packet in bounded pages or admit document context; no model call")
        @Argument var runID: String
        @Option(name: .long, help: "Exact section heading or heading block ID; offset counts blocks") var section: String?
        @Option(name: .long, help: "Find literal text in the versioned document") var find: String?
        @Option(name: .long, help: "Source S ID; offset counts UTF-8 bytes") var source: String?
        @Flag(name: .long, help: "Page the heading outline; offset counts headings") var outline = false
        @Option(name: .long, help: "Page input, policy, schema or manifest; offset counts UTF-8 bytes") var part: String?
        @Option(name: .long) var offset = 0
        @Option(name: .long, help: "Maximum text bytes per page/request (1–24000)") var limitBytes = 8_000
        @Flag(name: .long, help: "Re-read only this selected source and replace its version receipt within the original budget") var refresh = false
        func run() async throws {
            let choices = [("section", section), ("find", find), ("source", source), ("outline", outline ? "" : nil), ("part", part)].compactMap { item -> (String, String)? in
                item.1.map { (item.0, $0) }
            }
            guard choices.count == 1 else { throw ValidationError("Choose exactly one of --section, --find, --source, --outline or --part.") }
            let data = try await SecretaryPacketFiles.read(runID: runID, operation: choices[0].0, query: choices[0].1,
                offset: offset, limit: limitBytes, refresh: refresh)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct ApplyFiles: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "apply", abstract: "Validate and commit a prepared packet response; --dry-run validates without edits or marks")
        @Argument var runID: String
        @Option(name: .long, help: "Editor JSON response; use - to read stdin") var response: String
        @Flag(name: .long) var dryRun = false
        func run() async throws {
            let body = try response == "-" ? FileHandle.standardInput.readToEnd() ?? Data() : Data(contentsOf: URL(fileURLWithPath: (response as NSString).expandingTildeInPath))
            let data = try await SecretaryPacketFiles.apply(runID: runID, response: body, dryRun: dryRun)
            print(String(decoding: data, as: UTF8.self))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let findings = report?["findings"] as? [String], !findings.isEmpty { throw ExitCode(1) }
        }
    }

    struct CodexPacket: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "codex",
            abstract: "Preview or send a prepared format-2 packet to Codex and validate its JSON reply")
        @Argument(help: "Run ID from secretary prepare. Admit any additional sections with secretary read first.")
        var runID: String
        @Flag(name: .long, help: "Send the packet to Codex using the ChatGPT plan. By default only preview.")
        var send = false
        @Flag(name: .long, help: "With --send: commit the verified reply. By default only validate.")
        var apply = false
        @Option(name: .long, help: "Path to the Codex CLI binary")
        var binary: String?
        @Option(name: .long, help: "Any model ID supported by Codex CLI (default: Codex CLI chooses)")
        var model: String?
        @Option(name: .long, help: "Reasoning effort supported by the selected model (default: Codex CLI chooses)")
        var effort: String?

        func run() async throws {
            guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
            guard model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true,
                  effort?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true else {
                throw ValidationError("--model and --effort require non-empty values.")
            }
            guard send || !apply else { throw ValidationError("--apply requires --send.") }
            let executor: CodexExecutor?
            if !send {
                executor = nil
            } else if let binary {
                let url = URL(fileURLWithPath: (binary as NSString).expandingTildeInPath)
                guard FileManager.default.isExecutableFile(atPath: url.path) else {
                    throw ValidationError("Codex binary is not executable: \(url.path)")
                }
                executor = CodexExecutor(binary: url)
            } else {
                guard let url = CodexExecutor.locate() else {
                    throw ValidationError("Codex CLI not found. Set --binary or WIMM_CODEX_PATH.")
                }
                executor = CodexExecutor(binary: url)
            }
            let data = try await SecretaryPacketFiles.codex(runID: runID, executor: executor, commit: apply,
                                                           model: model, effort: effort)
            print(String(decoding: data, as: UTF8.self))
            let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let validation = report?["validation"] as? [String: Any],
               validation["accepted"] as? Bool != true || !(validation["findings"] as? [String] ?? []).isEmpty {
                throw ExitCode(1)
            }
        }
    }

    struct ReplayRun: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "replay", abstract: "Replay and apply the model output of an earlier packet run without re-running the model")
        @Argument(help: "Path to document") var document: String
        @Option(name: .long, help: "Run ID to replay (default: newest packet run)") var runID: String?
        @Flag(name: .long, help: "Apply changes; without it, performs a dry run") var apply = false

        struct StoredExecutionAgent: SecretaryExecutor {
            let name = "claude-code"
            let execution: SecretaryExecution
            func run(_ request: SecretaryExecutionRequest,
                     onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
                execution
            }
        }

        func run() async throws {
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            guard let wimmCLI = SecretaryDispatcher.locateWimmCLI() else { throw SecretaryError.wimmCLIMissing }
            guard let workspace = SecretaryWorkspace(document: url) else { throw SecretaryError.notAWorkspace(url.path) }
            let id: String
            if let runID { id = runID }
            else {
                let runs = (try FileManager.default.contentsOfDirectory(atPath: workspace.runsDirectory.path))
                    .filter { $0.range(of: #"^\d{8}-\d{6}-[a-f0-9]{4}$"#, options: .regularExpression) != nil }
                    .sorted()
                guard let last = runs.last else { throw ValidationError("No runs found in \(workspace.runsDirectory.path)") }
                id = last
            }
            let runDir = workspace.runDirectory(id)
            let execFile = runDir.appendingPathComponent("packet-execution.json")
            guard let execData = try? Data(contentsOf: execFile),
                  let execution = try? JSONDecoder().decode(SecretaryExecution.self, from: execData),
                  let _ = execution.finalText else {
                throw ValidationError("No packet-execution.json with final text in \(runDir.path)")
            }
            print("Run \(id) has packet execution (\(execution.tokensIn.map(String.init) ?? "unknown") tokens in, \(execution.tokensOut.map(String.init) ?? "unknown") out, cost \(execution.costUSD.map { String(format: "$%.4f", $0) } ?? "unknown")).")
            guard apply else {
                print("Dry run only. Use --apply to replay and apply edits, update registry, and advance boundary.")
                return
            }
            var dispatcher = SecretaryDispatcher(executor: StoredExecutionAgent(execution: execution),
                                                 wimmCLI: wimmCLI, budgetUSD: 10)
            dispatcher.packetMode = true
            let task = SecretaryTask(id: id, kind: .pass, workspace: workspace, threads: [], wimmCLI: wimmCLI.path, createdAt: Date(), packetMode: true)
            let record = try await dispatcher.run(task)
            print("Replay finished! Outcome: \(record.outcome?.rawValue ?? "unknown")")
            if let error = record.error {
                print("  Error: \(error)")
            }
            if let result = record.result {
                print("  Summary: \(result.summary ?? "none")")
                print("  Changed files: \(result.changedFiles?.joined(separator: ", ") ?? "none")")
            }
            if let bookkeeping = record.bookkeeping {
                print("  Registry updated: \(bookkeeping.registryUpdated), remaining: \(record.remainingNotes ?? 0)")
            }
        }
    }

    /// Pick a run: the named one or the newest.
    static func resolveRun(document: String, runID: String?) throws -> (SecretaryWorkspace, [String], String?) {
        let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
        guard let workspace = SecretaryWorkspace(document: url) else { throw SecretaryError.notAWorkspace(url.path) }
        let ids = SecretaryRunLog.runIDs(in: workspace)
        if let runID {
            guard ids.contains(runID) else { throw ValidationError("No run \(runID) in \(workspace.runsDirectory.path)") }
            return (workspace, ids, runID)
        }
        return (workspace, ids, ids.last)
    }

    struct RunLog: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "log", abstract: "Show what an earlier secretary run recorded: outcome, cost, findings, files; read-only, no model")
        @Argument(help: "Path to document") var document: String
        @Option(name: .long, help: "Run ID (default: newest)") var runID: String?
        @Flag(name: .long, help: "One line per run, newest last") var list = false
        @Option(name: .long, help: "With --list: only the last N runs") var last = 20

        func run() throws {
            let (workspace, ids, chosen) = try Secretary.resolveRun(document: document, runID: runID)
            if list {
                for id in ids.suffix(last) { print(SecretaryRunLog.summaryLine(SecretaryRunLog.entry(id: id, in: workspace))) }
                if ids.isEmpty { print("No runs in \(workspace.runsDirectory.path)") }
                return
            }
            guard let chosen else { throw ValidationError("No runs found in \(workspace.runsDirectory.path)") }
            print(SecretaryRunLog.report(SecretaryRunLog.entry(id: chosen, in: workspace)))
        }
    }

    struct RunCheck: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "check", abstract: "Check that earlier runs left a consistent trail (run.json, task, packet execution, usage); read-only, no model, exit 1 on problems")
        @Argument(help: "Path to document") var document: String
        @Option(name: .long, help: "Run ID (default: newest)") var runID: String?
        @Flag(name: .long, help: "Check every run, not only the newest") var all = false

        func run() throws {
            let (workspace, ids, chosen) = try Secretary.resolveRun(document: document, runID: runID)
            let targets = all ? ids : (chosen.map { [$0] } ?? [])
            guard !targets.isEmpty else { throw ValidationError("No runs found in \(workspace.runsDirectory.path)") }
            var bad = 0
            for id in targets {
                let entry = SecretaryRunLog.entry(id: id, in: workspace)
                print((entry.problems.isEmpty ? "ok   " : "FAIL ") + id)
                for p in entry.problems { print("       \(p)") }
                if !entry.problems.isEmpty { bad += 1 }
            }
            print("\(targets.count - bad)/\(targets.count) runs consistent")
            if bad > 0 { throw ExitCode(1) }
        }
    }

    struct Reconcile: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "reconcile", abstract: "Locally reconcile confirmed Trash entries, proven media aliases and missing S definitions; no model (dry run unless --apply)")
        @Argument var document: String
        @Flag(name: .long) var apply = false
        func run() async throws {
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            let report = try await SecretaryDispatcher.reconcile(document: url, apply: apply)
            let data = try JSONEncoder().encode(report)
            print(String(decoding: data, as: UTF8.self))
            if !apply { print("Dry run: no changes. Use --apply for the reported local repairs.") }
            if !report.findings.isEmpty { throw ExitCode(1) }
        }
    }

    struct Hold: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "hold", abstract: "Put exact registry sources on an explicit user hold (user_exclusion); no model (dry run unless --apply)")
        @Argument(help: "Workspace Markdown document") var document: String
        @Option(name: .long, parsing: .singleValue, help: "Note file name to hold (repeatable), e.g. Wimm_….txt") var file: [String] = []
        @Flag(name: .long, help: "Hold every note `wimm-cli notes lost-to-text` lists, as its future {base}.txt") var lostToText = false
        @Option(name: .long, help: "Why (stored in the hold)") var reason: String?
        @Option(name: .long, help: "Undo this hold run (…-hold) for the named files instead of holding")
        var undoRun: String?
        @Flag(name: .long, help: "With --undo-run: the files that run held which are no longer lost-to-text candidates")
        var noLongerLost = false
        @Flag(name: .long) var apply = false

        func run() throws {
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            if let undoRun {
                var files = file
                if noLongerLost {
                    let current = Set(LostMediaToText.scan().candidates.map { $0.base + ".txt" })
                    files += try SecretaryUserHold.heldFiles(document: url, runID: undoRun).filter { !current.contains($0) }
                }
                guard !files.isEmpty else { throw ValidationError("Nothing to undo: name files with --file or pass --no-longer-lost.") }
                let report = try SecretaryUserHold.undo(document: url, runID: undoRun, files: files, apply: apply)
                print(report.applied ? "APPLIED (run \(report.runID))" : "DRY RUN (registry unchanged)")
                print("To restore: \(report.held.count); not held by that run: \(report.notInRegistry.count); changed since: \(report.ambiguous.count)")
                for (source, name) in report.held.sorted(by: { $0.key < $1.key }) { print("  restore \(source) \(name)") }
                for name in report.notInRegistry { print("  not held by that run: \(name)") }
                for name in report.ambiguous { print("  changed since, left alone: \(name)") }
                if let backup = report.registryBackup { print("Backup: \(backup)") }
                if !report.notInRegistry.isEmpty || !report.ambiguous.isEmpty { throw ExitCode(1) }
                return
            }
            var files = file
            if lostToText { files += LostMediaToText.scan().candidates.map { $0.base + ".txt" } }
            guard !files.isEmpty else { throw ValidationError("Name notes with --file or pass --lost-to-text.") }
            let why = reason ?? (lostToText ? Self.lostToTextReason : nil)
            guard let why else { throw ValidationError("--reason is required.") }
            let report = try SecretaryUserHold.hold(document: url, files: files, reason: why, apply: apply)
            print(report.applied ? "APPLIED (run \(report.runID))" : "DRY RUN (registry unchanged)")
            print("To hold: \(report.held.count); already held: \(report.alreadyHeld.count); "
                  + "not in registry: \(report.notInRegistry.count); ambiguous: \(report.ambiguous.count)")
            for name in report.notInRegistry { print("  not in registry: \(name)") }
            for name in report.ambiguous { print("  ambiguous: \(name)") }
            if let backup = report.registryBackup { print("Backup: \(backup)") }
            if !report.notInRegistry.isEmpty || !report.ambiguous.isEmpty { throw ExitCode(1) }
        }

        static let lostToTextReason = "Решение Михаила 10.11.2026 («Hold for now»): заметки с утраченной аудиозаписью, превращённые в .txt (wimm-cli notes lost-to-text), секретарь не читает до явного возобновления; платный проход не одобрен. Пользовательское исключение, не содержательная оценка."
    }

    struct Registry: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "registry", abstract: "Read a bounded selection of source registry entries; no arguments prints the summary")
        @Argument var document: String
        @Option(name: .long, parsing: .singleValue) var source: [String] = []
        @Option(name: .long, parsing: .singleValue) var file: [String] = []
        @Option(name: .long) var query: String?
        @Option(name: .long) var limit = 20
        @Option(name: .long) var offset = 0

        func run() throws {
            guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
            let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
            let data = try SecretaryContext.registry(document: url, references: source + file, query: query, limit: limit, offset: offset)
            print(String(decoding: data, as: UTF8.self))
        }
    }

    struct CommentsRun: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "comments",
            abstract: "Answer the pending comment threads of a document with an outside agent (dry run unless --apply)")

        @Argument(help: "The Markdown document, inside a workspace with a secretary/ folder")
        var document: String
        @Flag(name: .long, help: "Start the agent; without it only the task is printed")
        var apply = false
        @Option(name: .long, help: "Which agent: codex (ChatGPT, default), claude, or gemini")
        var agent: String = SecretaryAgent.codex.rawValue
        @Option(name: .long, help: "Model (alias or full id); default: saved Settings choice, otherwise Sonnet for Claude or the Codex default")
        var model: String?
        @Option(name: .long, help: "Spending cap for the run in USD (claude only; Codex runs on the ChatGPT plan)")
        var budget: Double = 2
        @Option(name: .long, help: "Path to the agent's binary")
        var binary: String?
        @Option(name: .long, help: "Most Claude turns before the run stops (default: 100 for comments, 300 for a pass)")
        var maxTurns: Int?
        @Option(name: .long, help: "Reasoning effort: low, medium, high, xhigh, max (default: the agent's own)")
        var effort: String?

        func run() async throws {
            try await Secretary.execute(.comments, document: document, apply: apply, agent: agent, model: model,
                                        budget: budget, binary: binary, maxTurns: maxTurns, effort: effort)
        }
    }

    struct PassRun: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pass",
            abstract: "Run a full secretary pass by hand: open threads, then new and changed Wimm notes (dry run unless --apply)")

        @Argument(help: "The Markdown document, inside a workspace with a secretary/ folder")
        var document: String
        @Flag(name: .long, help: "Start the agent; without it only the task is printed")
        var apply = false
        @Option(name: .long, help: "Which agent: codex (ChatGPT, default), claude, or gemini")
        var agent: String = SecretaryAgent.codex.rawValue
        @Option(name: .long, help: "Model (alias or full id); default: saved Settings choice, otherwise Sonnet for Claude or the Codex default")
        var model: String?
        @Option(name: .long, help: "Spending cap for the run in USD (claude only; Codex runs on the ChatGPT plan)")
        var budget: Double = 2
        @Option(name: .long, help: "Path to the agent's binary")
        var binary: String?
        @Option(name: .long, help: "Most Claude turns before the run stops (default: 100 for comments, 300 for a pass)")
        var maxTurns: Int?
        @Option(name: .long, help: "Reasoning effort: low, medium, high, xhigh, max (default: the agent's own)")
        var effort: String?

        @Flag(name: .long, help: "Run even when no thread is open and no note is new or changed")
        var force = false
        @Option(name: .long, help: "Source packet size in KB: 64–1024, step 64 (default: saved choice or 512)")
        var packetKB: Int?
        @Option(name: .long, help: "Workflow: auto (workspace choice), packet (tool-free Claude, ChatGPT, or Gemini), agent (regular editor)")
        var workflow = "auto"

        func run() async throws {
            try await Secretary.execute(.pass, document: document, apply: apply, agent: agent, model: model,
                                        budget: budget, binary: binary, maxTurns: maxTurns, effort: effort, force: force, workflow: workflow, packetKB: packetKB)
        }
    }

    /// One run of `kind`: print the task (dry run) or start the agent and report what Wimm verified.
    static func execute(_ kind: SecretaryRunKind, document: String, apply: Bool, agent: String, model: String?,
                        budget: Double, binary: String?, maxTurns: Int? = nil, effort: String? = nil,
                        force: Bool = false, workflow: String = "auto", packetKB: Int? = nil) async throws {
        let url = URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL
        guard let wimmCLI = SecretaryDispatcher.locateWimmCLI() else { throw SecretaryError.wimmCLIMissing }
        guard let agent = SecretaryAgent(rawValue: agent) else {
            throw ValidationError("Unknown agent \(agent); use codex, claude or gemini.")
        }
        var environment = ProcessInfo.processInfo.environment
        if let binary { environment[agent == .claude ? "WIMM_CLAUDE_PATH" : "WIMM_CODEX_PATH"] = binary }
        let executor = try agent.executor(environment: environment)
        guard ["auto", "packet", "agent"].contains(workflow) else { throw ValidationError("Unknown workflow; use auto, packet or agent.") }
        var dispatcher = SecretaryDispatcher(executor: executor, wimmCLI: wimmCLI, budgetUSD: budget, model: agent.cliModel(override: model),
                                             maxTurns: maxTurns, effort: effort)
        dispatcher.packetMode = workflow == "auto" ? nil : workflow == "packet"
        if let packetKB {
            guard (SecretaryPacketSettings.minimumKB...SecretaryPacketSettings.maximumKB).contains(packetKB),
                  packetKB % SecretaryPacketSettings.stepKB == 0 else {
                throw ValidationError("Packet size must be 64–1024 KB in steps of 64.")
            }
            dispatcher.packetSourceKB = packetKB
        }
        let task: SecretaryTask
        do { task = kind == .pass ? try await dispatcher.preparePass(document: url, force: force) : try await dispatcher.prepareComments(document: url) }
        catch SecretaryError.nothingToDo { print(SecretaryError.nothingToDo.errorDescription ?? ""); return }

        guard apply else {
            if task.packetMode {
                print(try await dispatcher.packetPreview(task))
                print("Packet workflow: Claude or ChatGPT without tools, at most two requests. Pass --apply to run, or --workflow agent for the regular editor.")
                return
            }
            if kind == .pass, let scan = await SecretaryPassPlanner.scan() {
                print("Pending notes since \(scan.boundary): \(scan.pending) (\(scan.unmarked) unmarked, \(scan.pending - scan.unmarked) text changed since mark)"
                      + (scan.oldestPending.map { ", oldest change \($0)" } ?? ""))
            }
            print(task.markdown())
            print("---")
            print("Would run in \(task.workspace.root.path) with \(agent.displayName):")
            let preview = executor.previewCommand(for: .init(
                workspaceRoot: task.workspace.root, runDirectory: task.workspace.runDirectory(task.id), prompt: task.prompt,
                kind: task.kind, wimmCLI: wimmCLI.path, budgetUSD: budget, model: model, timeout: dispatcher.timeout(for: task.kind),
                maxTurns: maxTurns, effort: effort))
            let missing = await dispatcher.cliCheck(wimmCLI, task.kind)
            print("  Wimm CLI: \(wimmCLI.path)" + (missing.isEmpty ? "" : " — too old, missing: \(missing.joined(separator: ", "))"))
            print("  " + preview.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))
            print("  stdin: \(task.prompt)")
            print("Dry run — pass --apply to start the agent.")
            return
        }

        let record = try await dispatcher.run(task) { event in
            let mark = switch event.kind { case .info: "·"; case .text: "›"; case .tool: "⚙"; case .error: "!" }
            print("\(mark) \(event.message)")
        }
        print("")
        print("Run \(record.id): \(record.outcome?.rawValue ?? "?")"
              + (record.costUSD.map { String(format: " · $%.2f", $0) } ?? "")
              + (record.turns.map { " · \($0) turns" } ?? ""))
        if let remaining = record.remainingNotes { print("Notes remaining (host scan): \(remaining)") }
        if let summary = record.result?.summary { print(summary) }
        if let error = record.error { print("Error: \(error)") }
        if !record.findings.isEmpty {
            print("Findings:")
            for finding in record.findings { print("  - \(finding)") }
        }
        print("Record: \(task.workspace.runDirectory(task.id).appendingPathComponent("run.json").path)")
        if let backup = record.backup { print("Backup: \(backup)") }
        if record.outcome != .succeeded || !record.findings.isEmpty { throw ExitCode(1) }
    }
}
