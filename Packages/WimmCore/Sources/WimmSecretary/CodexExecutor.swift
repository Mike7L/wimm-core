import Foundation
import WimmInfrastructure

/// OpenAI's Codex CLI (the copy inside ChatGPT.app, already signed in with the
/// ChatGPT account) in non-interactive `exec` mode with JSONL events
/// (`docs/Secretary_Dispatcher.md`).
///
/// Limits are coarser than Claude's allow list: the sandbox is
/// `workspace-write` (the workspace is writable, `.git` is not, no network
/// for commands), so "nothing outside docs/ and secretary/" is enforced by
/// Wimm's verification afterwards, not by the agent's sandbox. The `wimm`
/// MCP server is limited to the read-only tools.
public struct CodexExecutor: SecretaryExecutor {
    public let name = "codex"
    public let supportsPacketSessions = true
    public let binary: URL

    public init(binary: URL) { self.binary = binary }

    public static let pathDefaultsKey = "Secretary.codexPath"

    /// `WIMM_CODEX_PATH`, the defaults key, PATH, then ChatGPT.app's bundled copy.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults = .standard,
                              home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL? {
        var candidates: [String] = []
        if let explicit = environment["WIMM_CODEX_PATH"] { candidates.append(explicit) }
        if let configured = defaults.string(forKey: pathDefaultsKey) { candidates.append(configured) }
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        let bundled = "ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        candidates += ["/Applications/\(bundled)", home.appendingPathComponent("Applications/\(bundled)").path,
                       "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        for path in candidates where !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        return nil
    }

    static func toml(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public func arguments(for request: SecretaryExecutionRequest, lastMessage: URL) -> [String] {
        if request.systemPrompt != nil {
            var args = ["exec", "--json", "--ignore-user-config", "--skip-git-repo-check",
                        "-s", "read-only", "-C", request.workspaceRoot.path, "-o", lastMessage.path]
            if request.outputJSONSchema != nil { args += ["--output-schema", request.runDirectory.appendingPathComponent("output-schema.json").path] }
            if !request.packetSession { args += ["--ephemeral"] }
            if let model = request.model, !model.isEmpty { args += ["-m", model] }
            if let effort = request.effort, !effort.isEmpty { args += ["-c", "model_reasoning_effort=\(Self.toml(effort))"] }
            args += ["-c", "model_instructions_file=\(Self.toml(request.runDirectory.appendingPathComponent("system.md").path))",
                     "-c", "forced_login_method=\"chatgpt\"",
                     "-c", "project_doc_max_bytes=0", "-c", "approval_policy=\"never\"",
                     "-c", "features.shell_tool=false", "-c", "features.apps=false", "-c", "features.plugins=false",
                     "-c", "features.multi_agent=false", "-c", "agents.enabled=false", "-c", "features.skill_search=false",
                     "-c", "features.skip_host_skill_discovery=true", "-c", "features.view_image=false",
                     "-c", "skills.include_instructions=false", "-c", "skills.bundled.enabled=false",
                     "-c", "features.sleep_tool=false",
                     "-c", "memories.use_memories=false", "-c", "web_search=\"disabled\""]
            if let id = request.resumeSessionID { args += ["resume", id] }
            args += ["-"]
            return args
        }
        var arguments = [
            "exec", "--json", "--ephemeral",
            // The user's own config carries plugins and a turn-ended hook that
            // opens another app; a secretary run must not depend on it.
            "--ignore-user-config", "--skip-git-repo-check",
            "-s", "workspace-write", "-C", request.workspaceRoot.path,
            "-o", lastMessage.path,
        ]
        if let model = request.model, !model.isEmpty { arguments += ["-m", model] }
        if let effort = request.effort, !effort.isEmpty { arguments += ["-c", "model_reasoning_effort=\(Self.toml(effort))"] }
        let tools = "[" + request.kind.wimmTools.map(Self.toml).joined(separator: ",") + "]"
        arguments += [
            "-c", "mcp_servers.wimm.command=\(Self.toml(request.wimmCLI))",
            "-c", "mcp_servers.wimm.args=[\"mcp\"]",
            "-c", "mcp_servers.wimm.enabled_tools=\(tools)",
            "-c", "mcp_servers.wimm.env={" + request.mcpEnvironment.sorted { $0.key < $1.key }
                .map { "\($0.key)=\(Self.toml($0.value))" }.joined(separator: ",") + "}",
            // `exec` never asks; without this an MCP call fails with "requires approval".
            "-c", "mcp_servers.wimm.default_tools_approval_mode=\"approve\"",
            // The prompt comes from stdin.
            "-",
        ]
        return arguments
    }

    public func previewCommand(for request: SecretaryExecutionRequest) -> [String] {
        [binary.path] + arguments(for: request, lastMessage: request.runDirectory.appendingPathComponent("last-message.txt"))
    }

    public func run(_ request: SecretaryExecutionRequest,
                    onEvent: @escaping @Sendable (SecretaryEvent) -> Void) async throws -> SecretaryExecution {
        try request.validatePacketResume()
        if let system = request.systemPrompt {
            try system.write(to: request.runDirectory.appendingPathComponent("system.md"), atomically: true, encoding: .utf8)
        }
        if let schema = request.outputJSONSchema {
            try schema.write(to: request.runDirectory.appendingPathComponent("output-schema.json"), options: .atomic)
        }
        let lastMessage = request.runDirectory.appendingPathComponent("last-message.txt")
        var execution = SecretaryExecution(exitStatus: -1, model: request.model)
        let outcome = try await SecretaryProcessRunner.run(
            binary: binary, arguments: arguments(for: request, lastMessage: lastMessage),
            environment: SecretaryProcessRunner.managedEnvironment(SecretaryProcessRunner.cleanEnvironment(ProcessInfo.processInfo.environment), request: request),
            request: request, stdin: request.prompt, onEvent: onEvent) { line in
            Self.parse(line: line, into: &execution, onEvent: onEvent)
        }
        outcome.apply(to: &execution, name: name)
        if execution.finalText == nil,
           let text = try? String(contentsOf: lastMessage, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            execution.finalText = text
        }
        return execution
    }

    /// One JSONL event. Unknown shapes are ignored, never fatal.
    static func parse(line: String, into execution: inout SecretaryExecution,
                      onEvent: (SecretaryEvent) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return }
        let item = object["item"] as? [String: Any] ?? [:]
        switch type {
        case "thread.started":
            execution.sessionID = object["thread_id"] as? String
        case "item.started":
            switch item["type"] as? String {
            case "command_execution":
                onEvent(.init(.tool, "Bash: " + SecretaryTask.oneLine(shellCommand(item["command"] as? String ?? ""), limit: 200)))
            case "mcp_tool_call":
                onEvent(.init(.tool, "\(item["server"] as? String ?? "mcp"): \(item["tool"] as? String ?? "tool")"))
            default: break
            }
        case "item.completed":
            switch item["type"] as? String {
            case "agent_message":
                if let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    execution.finalText = text
                    onEvent(.init(.text, text))
                }
            case "command_execution":
                if let code = (item["exit_code"] as? NSNumber)?.intValue, code != 0 {
                    let output = SecretaryTask.oneLine(item["aggregated_output"] as? String ?? "", limit: 200)
                    onEvent(.init(.error, "exit \(code): " + SecretaryTask.oneLine(shellCommand(item["command"] as? String ?? ""), limit: 120)
                                  + (output.isEmpty ? "" : " — \(output)")))
                }
            case "mcp_tool_call":
                if let message = (item["error"] as? [String: Any])?["message"] as? String {
                    onEvent(.init(.error, "\(item["tool"] as? String ?? "mcp"): \(SecretaryTask.oneLine(message, limit: 200))"))
                }
            case "file_change":
                let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String } ?? []
                if !paths.isEmpty { onEvent(.init(.tool, "edit: " + paths.joined(separator: ", "))) }
            case "error":
                if let message = item["message"] as? String { onEvent(.init(.error, SecretaryTask.oneLine(message, limit: 300))) }
            default: break
            }
        case "turn.completed":
            if let usage = object["usage"] as? [String: Any] {
                let count = { (key: String) in (usage[key] as? NSNumber)?.intValue ?? 0 }
                execution.tokensIn = (execution.tokensIn ?? 0) + count("input_tokens")
                execution.tokensOut = (execution.tokensOut ?? 0) + count("output_tokens") + count("reasoning_output_tokens")
            }
            execution.turns = (execution.turns ?? 0) + 1
        case "turn.failed", "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String ?? type
            onEvent(.init(.error, SecretaryTask.oneLine(message, limit: 300)))
            // `error` also announces reconnects; only a failed turn ends the run.
            if type == "turn.failed" { execution.isError = true; execution.error = message }
        default:
            break
        }
    }

    /// `/bin/zsh -lc 'cat a.txt'` → `cat a.txt`.
    static func shellCommand(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -lc ", "zsh -lc ", "bash -lc "] where command.hasPrefix(prefix) {
            var rest = String(command.dropFirst(prefix.count))
            if let quote = rest.first, quote == "'" || quote == "\"", rest.last == quote, rest.count >= 2 {
                rest = String(rest.dropFirst().dropLast())
            }
            return rest
        }
        return command
    }
}
