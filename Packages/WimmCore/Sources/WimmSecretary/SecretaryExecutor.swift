import Foundation
import WimmInfrastructure

/// A line of progress from the agent, for the live log.
public struct SecretaryEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case info, text, tool, error }
    public let kind: Kind
    public let message: String
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
}

public struct SecretaryExecutionRequest: Sendable {
    public let workspaceRoot: URL
    public let runDirectory: URL
    public let prompt: String
    public let kind: SecretaryRunKind
    public let wimmCLI: String
    public let budgetUSD: Double
    public let model: String?
    public let timeout: TimeInterval
    /// Agent turns at most; nil: the run kind's ceiling.
    /// Receipts live in Wimm's AgentState, outside the agent's writable workspace.
    public var mcpEnvironment: [String: String] {
        var environment = kind.mcpEnvironment
        // Preserve an explicitly selected library/profile in the MCP child.
        // Otherwise an isolated CLI run may unexpectedly read the default library.
        for key in ["WIMM_BASE_DIR","WIMM_DEFAULTS_SUITE","WIMM_APP_DEFAULTS_DOMAIN","WIMM_PRIVATE_MODE"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
        if systemPrompt == nil {
            environment[MCPRecallServer.readLogEnvironmentKey] = SecretaryReadReceipt.logURL(runID: runDirectory.lastPathComponent).path
        }
        if let reviewBackup {
            let context = SecretaryCompletion.ReviewContext(document: workspaceRoot.appendingPathComponent(reviewDocument), backup: reviewBackup,
                log: SecretaryReadReceipt.logURL(runID: runDirectory.lastPathComponent).appendingPathExtension("review"))
            if let data = try? JSONEncoder().encode(context) {
                environment[SecretaryCompletion.reviewEnvironmentKey] = String(decoding: data, as: UTF8.self)
            }
        }
        return environment
    }
    public var reviewBackup: URL? = nil
    public var reviewDocument: String = ""
    public let maxTurns: Int?
    /// Reasoning effort (`low` … `max`) for agents that take one; nil: the agent's default.
    public let effort: String?
    /// A tool-free packet invocation. The host supplies all data and applies the JSON result.
    public var systemPrompt: String? = nil
    /// Optional syntax constraints; semantic validation and receipts remain host-owned.
    public var outputJSONSchema: Data? = nil
    /// Only sessions created by this dispatcher invocation may be continued.
    public var packetSession = false
    public var resumeSessionID: String? = nil

    public init(workspaceRoot: URL, runDirectory: URL, prompt: String, kind: SecretaryRunKind, wimmCLI: String,
                budgetUSD: Double, model: String?, timeout: TimeInterval, maxTurns: Int? = nil, effort: String? = nil) {
        self.workspaceRoot = workspaceRoot; self.runDirectory = runDirectory; self.prompt = prompt; self.kind = kind
        self.wimmCLI = wimmCLI; self.budgetUSD = budgetUSD; self.model = model; self.timeout = timeout
        self.maxTurns = maxTurns; self.effort = effort
    }
}

public struct SecretaryExecution: Codable, Sendable, Equatable {
    public var exitStatus: Int32
    public var isError = false
    public var finalText: String?
    public var costUSD: Double?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var turns: Int?
    public var sessionID: String?
    public var model: String?
    public var error: String?

    public init(exitStatus: Int32, isError: Bool = false, finalText: String? = nil, costUSD: Double? = nil,
                tokensIn: Int? = nil, tokensOut: Int? = nil, turns: Int? = nil, sessionID: String? = nil,
                model: String? = nil, error: String? = nil) {
        self.exitStatus = exitStatus; self.isError = isError; self.finalText = finalText; self.costUSD = costUSD
        self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.turns = turns; self.sessionID = sessionID
        self.model = model; self.error = error
    }
}

/// One outside agent. The dispatcher owns everything else (task, lock,
/// backup, verification); an executor only starts the agent and reports.
public protocol SecretaryExecutor: Sendable {
    var name: String { get }
    var supportsPacketSessions: Bool { get }
    func run(_ request: SecretaryExecutionRequest,
             onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution
    /// The command a run would start, for a dry run; empty when not meaningful.
    func previewCommand(for request: SecretaryExecutionRequest) -> [String]
}

public extension SecretaryExecutor {
    var supportsPacketSessions: Bool { false }
    func previewCommand(for request: SecretaryExecutionRequest) -> [String] { [] }
}

/// Claude Code in print mode with streamed JSON, `dontAsk` permissions and
/// an explicit allow list (`docs/Secretary_Dispatcher.md` §4).
public struct ClaudeCodeExecutor: SecretaryExecutor {
    public let name = "claude-code"
    public let supportsPacketSessions = true
    public let binary: URL

    public init(binary: URL) { self.binary = binary }

    public static let pathDefaultsKey = "Secretary.claudePath"

    /// `WIMM_CLAUDE_PATH`, the defaults key, PATH and the usual install
    /// places, then the copy the Claude desktop app manages (newest version).
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard,
                              home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let explicit = environment["WIMM_CLAUDE_PATH"] { candidates.append(explicit) }
        if let configured = defaults.string(forKey: pathDefaultsKey) { candidates.append(configured) }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
        candidates += [".local/bin/claude", ".claude/local/claude"].map { home.appendingPathComponent($0).path }
        candidates += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for path in candidates where !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        return desktopManagedCopy(home: home)
    }

    static func desktopManagedCopy(home: URL) -> URL? {
        let base = home.appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
        let fm = FileManager.default
        let versions = ((try? fm.contentsOfDirectory(atPath: base.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let versionURL = base.appendingPathComponent(version, isDirectory: true)
            for build in (try? fm.contentsOfDirectory(atPath: versionURL.path)) ?? [] {
                let binary = versionURL.appendingPathComponent("\(build)/claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: binary.path) { return binary }
            }
        }
        return nil
    }

    /// What a run may do. Path rules are relative to the workspace (the
    /// process's working directory); the `wimm` tools depend on the run kind.
    public static func allowedTools(wimmCLI: String, kind: SecretaryRunKind = .comments, root: String? = nil) -> [String] {
        // `Edit(docs/**)` is relative to the shell's current directory, which a `cd` in Bash moves: after
        // `cd docs` every Write was denied. The `//`-absolute twins do not drift.
        let absolute = root.map { ["Edit(/\($0)/docs/**)", "Edit(/\($0)/secretary/**)"] } ?? []
        return [
            "Read", "Grep", "Glob",
            // Edit rules cover every file-editing tool; `Write(path)` rules are rejected as unmatched.
            "Edit(docs/**)", "Edit(secretary/**)",
        ] + absolute + [
            // Phase 1 is a learning phase: Bash is open, because the agent's multi-line scripts and heredocs
            // were refused piecemeal by command patterns. Edit rules do not bind a shell, so the after-run
            // check that nothing changed outside docs/ and secretary/ (`allowedPrefixes` in SecretaryRun.swift)
            // and `disallowedTools` are what keep this safe.
            "Bash",
        ] + kind.wimmTools.map { "mcp__wimm__\($0)" }
    }

    /// The built-in tools a run gets at all (`--tools`); `allowedTools` decides what they may touch.
    /// No `Skill`: it lists every installed skill and plugin in every turn (18.9k → 10.8k tokens of
    /// start-up prefix without it, 2026-10-26), and the task names the skill file to `Read` instead.
    public static let builtInTools = ["Read", "Edit", "Write", "Grep", "Glob", "Bash"]

    /// Denied even with Bash open: network, privilege, destruction and publishing.
    public static let disallowedTools = [
        "Bash(curl *)", "Bash(wget *)", "Bash(ssh *)", "Bash(scp *)", "Bash(nc *)", "Bash(sudo *)",
        "Bash(rm -rf *)", "Bash(rm -fr *)", "Bash(git push *)", "Bash(git commit *)", "Bash(git reset *)",
        "Bash(git checkout *)", "Bash(open *)", "Bash(osascript *)",
    ]

    public static func mcpConfig(wimmCLI: String, environment: [String: String] = [:]) -> Data {
        var server: [String: Any] = ["type": "stdio", "command": wimmCLI, "args": ["mcp"]]
        if !environment.isEmpty { server["env"] = environment }
        let config: [String: Any] = ["mcpServers": ["wimm": server]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public func arguments(for request: SecretaryExecutionRequest, mcpConfig: URL) -> [String] {
        if request.systemPrompt != nil {
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "dontAsk",
                        "--safe-mode", "--setting-sources", "", "--disable-slash-commands",
                        "--tools", "", "--strict-mcp-config", "--mcp-config", mcpConfig.path,
                        "--system-prompt-file", request.runDirectory.appendingPathComponent("system.md").path,
                        "--max-budget-usd", String(format: "%.2f", request.budgetUSD), "--max-turns", "1"]
            if let id = request.resumeSessionID { args += ["--resume", id] }
            if let model = request.model { args += ["--model", model] }
            if let effort = request.effort { args += ["--effort", effort] }
            return args
        }
        var arguments = [
            "-p",
            "--output-format", "stream-json", "--verbose",
            "--permission-mode", "dontAsk",
            "--mcp-config", mcpConfig.path, "--strict-mcp-config",
            "--max-budget-usd", String(format: "%.2f", request.budgetUSD),
        ]
        if let model = request.model, !model.isEmpty { arguments += ["--model", model] }
        arguments += ["--max-turns", String(request.maxTurns ?? request.kind.maxTurns)]
        if let effort = request.effort, !effort.isEmpty { arguments += ["--effort", effort] }
        // Only the built-ins a run uses: every other tool's schema rides in the
        // prompt of every turn (39 tools by default).
        arguments += ["--tools", Self.builtInTools.joined(separator: ",")]
        arguments += ["--disallowedTools"] + Self.disallowedTools
        // Variadic: keep it last so it cannot swallow another argument.
        arguments.append("--allowedTools")
        arguments += Self.allowedTools(wimmCLI: request.wimmCLI, kind: request.kind, root: request.workspaceRoot.path)
        return arguments
    }

    public func previewCommand(for request: SecretaryExecutionRequest) -> [String] {
        [binary.path] + arguments(for: request, mcpConfig: request.runDirectory.appendingPathComponent("mcp.json"))
    }

    public func run(_ request: SecretaryExecutionRequest,
                    onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        try request.validatePacketResume()
        let mcpConfig = request.runDirectory.appendingPathComponent("mcp.json")
        if let system = request.systemPrompt {
            try Data(system.utf8).write(to: request.runDirectory.appendingPathComponent("system.md"), options: .atomic)
            try Data("{\"mcpServers\":{}}".utf8).write(to: mcpConfig, options: .atomic)
        } else {
            try Self.mcpConfig(wimmCLI: request.wimmCLI, environment: request.mcpEnvironment).write(to: mcpConfig, options: .atomic)
        }
        var execution = SecretaryExecution(exitStatus: -1)
        // The prompt goes through stdin: `-p` would otherwise take the next
        // argument, and the variadic allow list would take a trailing prompt.
        let outcome = try await SecretaryProcessRunner.run(
            binary: binary, arguments: arguments(for: request, mcpConfig: mcpConfig), environment: SecretaryProcessRunner.managedEnvironment(Self.environment(), request: request),
            request: request, stdin: request.prompt, onEvent: onEvent) { line in
            Self.parse(line: line, into: &execution, onEvent: onEvent)
        }
        outcome.apply(to: &execution, name: name)
        return execution
    }

    static func environment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = inherited
        // Started from inside a Claude Code session (a terminal in the Claude
        // app, a `wimm-cli` run by an agent), the host's session variables and
        // its API proxy would leak into the child, which then is not the
        // owner's own login ("Credit balance is too low", seen 2026-10-25).
        if inherited["CLAUDECODE"] != nil {
            for key in environment.keys where key.hasPrefix("CLAUDE") || key == "ANTHROPIC_BASE_URL" {
                environment.removeValue(forKey: key)
            }
        }
        // A run's turns follow each other within seconds, so the 5-minute
        // cache holds; the default 1-hour write costs 2× input instead of 1.25×.
        environment["FORCE_PROMPT_CACHING_5M"] = "1"
        // The owner's auto-memory index is not the secretary's business.
        environment["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        return SecretaryProcessRunner.cleanEnvironment(environment)
    }

    /// One `stream-json` line. Unknown shapes are ignored, never fatal.
    static func parse(line: String, into execution: inout SecretaryExecution,
                      onEvent: (SecretaryEvent) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }
        switch type {
        case "system":
            if object["subtype"] as? String == "init" {
                execution.model = object["model"] as? String
                execution.sessionID = object["session_id"] as? String
                onEvent(.init(.info, "model \(execution.model ?? "?")"))
            }
        case "assistant":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for part in content {
                switch part["type"] as? String {
                case "text":
                    if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        onEvent(.init(.text, text))
                    }
                case "tool_use":
                    onEvent(.init(.tool, toolSummary(name: part["name"] as? String ?? "tool", input: part["input"] as? [String: Any] ?? [:])))
                default: break
                }
            }
        case "user":
            let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            for part in content where part["type"] as? String == "tool_result" && part["is_error"] as? Bool == true {
                let text: String
                if let string = part["content"] as? String { text = string }
                else { text = (part["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? "tool error" }
                onEvent(.init(.error, SecretaryTask.oneLine(text, limit: 300)))
            }
        case "result":
            execution.isError = object["is_error"] as? Bool ?? false
            execution.finalText = object["result"] as? String
            execution.costUSD = (object["total_cost_usd"] as? NSNumber)?.doubleValue
            execution.turns = (object["num_turns"] as? NSNumber)?.intValue
            execution.sessionID = object["session_id"] as? String ?? execution.sessionID
            if let usage = object["usage"] as? [String: Any] {
                let count = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
                execution.tokensIn = count("input_tokens") + count("cache_read_input_tokens") + count("cache_creation_input_tokens")
                execution.tokensOut = count("output_tokens")
            }
            let subtype = object["subtype"] as? String ?? ""
            if execution.isError || subtype != "success" {
                execution.isError = true
                execution.error = execution.finalText ?? subtype
            }
            if let denials = object["permission_denials"] as? [[String: Any]], !denials.isEmpty {
                let names = denials.compactMap { $0["tool_name"] as? String }
                onEvent(.init(.error, "denied: \(names.joined(separator: ", "))"))
            }
        default:
            break
        }
    }

    static func toolSummary(name: String, input: [String: Any]) -> String {
        let detail = input["command"] as? String ?? input["file_path"] as? String ?? input["pattern"] as? String
            ?? input["query"] as? String ?? input["reference"] as? String ?? input["id"] as? String
        return detail.map { "\(name): \(SecretaryTask.oneLine($0, limit: 200))" } ?? name
    }
}

/// Starts an agent process in the workspace, feeds the prompt on stdin, keeps
/// the raw stream as `transcript.jsonl` and hands each stdout line to `parse`.
/// Shared by every adapter; what a line means is the adapter's business.
enum SecretaryProcessRunner {
    struct Outcome {
        let status: Int32
        let signaled: Bool
        let stderr: String

        /// A non-zero exit or a fatal signal is an error, whatever the stream said.
        func apply(to execution: inout SecretaryExecution, name: String) {
            execution.exitStatus = status
            guard signaled || status != 0 else { return }
            execution.isError = true
            if execution.error == nil {
                execution.error = stderr.isEmpty ? "\(name) exited with \(status)" : String(stderr.suffix(2000))
            }
        }
    }

    static func run(binary: URL, arguments: [String], environment: [String: String],
                    request: SecretaryExecutionRequest, stdin: String,
                    onEvent: @Sendable (SecretaryEvent) -> Void,
                    parse: (String) -> Void) async throws -> Outcome {
        #if os(macOS)
        let transcriptURL = request.runDirectory.appendingPathComponent("transcript.jsonl")
        FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        let transcript = try FileHandle(forWritingTo: transcriptURL)
        defer { try? transcript.close() }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.currentDirectoryURL = request.workspaceRoot
        process.environment = environment
        // A large packet can fill a pipe before the child starts reading. An
        // unlinked file also lets a child exit early without a broken pipe.
        let inputURL = request.runDirectory.appendingPathComponent("stdin-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: inputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: inputURL) }
        let input = try FileHandle(forUpdating: inputURL)
        defer { try? input.close() }
        try FileManager.default.removeItem(at: inputURL)
        try input.write(contentsOf: Data(stdin.utf8))
        try input.seek(toOffset: 0)
        let output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        onEvent(.init(.info, "\(binary.lastPathComponent) · \(request.workspaceRoot.path)"))
        try process.run()

        let stderrTask = Task.detached { () -> String in
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        let deadline = Task.detached {
            try await Task.sleep(for: .seconds(request.timeout))
            if process.isRunning { process.terminate() }
        }
        defer { deadline.cancel() }

        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                transcript.write(Data((line + "\n").utf8))
                parse(line)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        let stderr = await stderrTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        return Outcome(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal, stderr: stderr)
        #else
        throw SecretaryError.unsupportedPlatform
        #endif
    }

    static let managedEnvironmentKey = "WIMM_SECRETARY_HOST_BOOKKEEPING"

    static func managedEnvironment(_ inherited: [String: String], request: SecretaryExecutionRequest) -> [String: String] {
        var environment = inherited
        if request.kind == .pass,
           ["managed.md", "managed-review.md"].contains(where: {
               FileManager.default.fileExists(atPath: request.workspaceRoot.appendingPathComponent("secretary/protocol/" + $0).path)
           }) {
            environment[managedEnvironmentKey] = "1"
        }
        return environment
    }

    /// An agent started from inside a Claude Code session must not look nested.
    static func cleanEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return environment
    }
}

/// A preset model choice for an outside secretary agent.
public struct SecretaryModelOption: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

/// The outside agents a run can be given to. The window and the CLI pick one;
/// everything else about a run is the same for all of them.
public enum SecretaryAgent: String, CaseIterable, Sendable, Identifiable {
    case codex, claude, gemini
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: "ChatGPT (Codex)"
        case .claude: "Claude Code"
        case .gemini: "Gemini"
        }
    }

    public var modelDefaultsKey: String { "Secretary.model.\(rawValue)" }

    /// Default model when none is stored in UserDefaults.
    /// Claude Code CLI defaults to Opus on a subscription when `--model` is omitted,
    /// so Wimm explicitly defaults Claude secretary runs to `sonnet`.
    public var defaultModel: String {
        switch self {
        case .codex: ""
        case .claude: "sonnet"
        case .gemini: "gemini-flash-latest"
        }
    }

    public var modelOptions: [SecretaryModelOption] {
        switch self {
        case .codex:
            []
        case .claude:
            [
                SecretaryModelOption(id: "sonnet", displayName: "Sonnet"),
                SecretaryModelOption(id: "opus", displayName: "Opus"),
                SecretaryModelOption(id: "haiku", displayName: "Haiku"),
            ]
        case .gemini:
            [
                SecretaryModelOption(id: "gemini-flash-latest", displayName: "Gemini Flash"),
                SecretaryModelOption(id: "gemini-pro-latest", displayName: "Gemini Pro"),
            ]
        }
    }

    public func modelOptions(including current: String) -> [SecretaryModelOption] {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !modelOptions.isEmpty, !modelOptions.contains(where: { $0.id == trimmed }) else {
            return modelOptions
        }
        return modelOptions + [SecretaryModelOption(id: trimmed, displayName: trimmed)]
    }

    public func preferredModel(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: modelDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        return defaultModel
    }

    public func resolvedModel(override: String?, defaults: UserDefaults = .standard) -> String? {
        let explicit = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = explicit.isEmpty ? preferredModel(defaults: defaults) : explicit
        return model.isEmpty ? nil : model
    }

    /// The CLI has a separate defaults domain from the macOS Settings window.
    /// Isolated/test processes must never consult the user's app preferences.
    public func cliModel(override: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard !APIKeySecureStore.isRunningTests() else { return resolvedModel(override: override) }
        let configuredDomain = environment["WIMM_APP_DEFAULTS_DOMAIN"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let domain = configuredDomain.isEmpty ? appSettingsDefaultsDomain : configuredDomain
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        return resolvedModel(override: override, defaults: defaults)
    }

    public static let defaultsKey = "Secretary.agent"
    /// ChatGPT first: it is the one whose login works from a plain subprocess.
    public static var preferred: SecretaryAgent {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SecretaryAgent.init(rawValue:)) ?? .codex
    }

    public func executor(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> SecretaryExecutor {
        switch self {
        case .claude:
            guard let binary = ClaudeCodeExecutor.locate(environment: environment) else {
                throw SecretaryError.executorMissing(displayName)
            }
            return ClaudeCodeExecutor(binary: binary)
        case .codex:
            guard let binary = CodexExecutor.locate(environment: environment) else {
                throw SecretaryError.executorMissing(displayName)
            }
            return CodexExecutor(binary: binary)
        case .gemini:
            return GeminiPacketExecutor()
        }
    }
}

extension SecretaryExecutionRequest {
    func validatePacketResume() throws {
        if let id = resumeSessionID {
            guard packetSession, systemPrompt != nil, UUID(uuidString: id) != nil else {
                throw SecretaryPacket.Failure("Invalid secretary packet session continuation.")
            }
        }
    }
}
