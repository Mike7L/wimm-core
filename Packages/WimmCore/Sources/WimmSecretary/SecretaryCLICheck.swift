import Foundation
import WimmInfrastructure

/// Whether a Wimm CLI can serve a secretary run, asked from the CLI itself:
/// `mcp` with the run's environment, `initialize` + `tools/list`, nothing else.
/// An old copy answers to unknown arguments by ignoring them — on 2026-10-26 the
/// copy in `~/.local/share/wimm/` listed 1894 "changed" notes where the real
/// queue was 1694, because it did not know `marked_changes` — so a run refuses
/// such a copy before the agent spends anything. Capabilities, not versions:
/// a build from any branch passes as long as it has what the task asks for.
public enum SecretaryCLICheck {
    /// The MCP tools and arguments the task of `kind` relies on.
    static func required(for kind: SecretaryRunKind) -> [String: [String]] {
        var tools: [String: [String]] = ["search_notes": ["query", "limit"], "get_note": ["id", "full"], "recent_notes": ["since", "limit"], "secretary_review_document": ["page"]]
        if kind == .pass {
            tools["get_note"] = ["id", "full"]
            tools["changed_notes"] = ["since", "cursor", "skip_unchanged_marked", "marked_changes", "order", "limit"]
            tools["marked_notes"] = ["changed_since_mark", "limit"]
        }
        return tools
    }

    /// What is missing from a `tools/list` reply; empty when the CLI fits.
    /// With a page cap the listing tools must advertise it as `maximum`, or the
    /// server ignores the cap.
    static func missing(tools: [[String: Any]], kind: SecretaryRunKind, pageLimit: Int?) -> [String] {
        var byName: [String: [String: Any]] = [:]
        for tool in tools {
            if let name = tool["name"] as? String { byName[name] = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:] }
        }
        var missing: [String] = []
        for (tool, arguments) in required(for: kind).sorted(by: { $0.key < $1.key }) {
            guard let properties = byName[tool] else { missing.append(tool); continue }
            missing += arguments.filter { properties[$0] == nil }.map { "\(tool).\($0)" }
            if let pageLimit, arguments.contains("limit"), let limit = properties["limit"] as? [String: Any],
               (limit["maximum"] as? NSNumber)?.intValue != pageLimit {
                missing.append("\(tool).limit ≤ \(pageLimit)")
            }
        }
        if tools.first(where: { $0["name"] as? String == "get_note" })?[SecretaryReadReceipt.capability] as? Int != 1 {
            missing.append("get_note.read_receipts")
        }
        if tools.first(where: { $0["name"] as? String == "get_note" })?[SecretaryReadReceipt.coverageCapability] as? Int != 1 {
            missing.append("get_note.text_coverage")
        }
        if kind == .pass, tools.first(where: { $0["name"] as? String == "changed_notes" })?[SecretaryCompletion.queueCapability] as? Int != 1 {
            missing.append("changed_notes.queue_receipts")
        }
        if tools.first(where: { $0["name"] as? String == "get_note" })?["x-wimm-image-evidence"] as? Int != 1 {
            missing.append("get_note.image_evidence")
        }
        if tools.first(where: { $0["name"] as? String == "get_note" })?["x-wimm-document-layout"] as? Int != 1 {
            missing.append("get_note.document_layout")
        }
        return missing
    }

    /// Starts `<cli> mcp`, asks for its tools and stops it. A CLI that does not
    /// answer within `timeout` is missing everything.
    public static func missing(cli: URL, kind: SecretaryRunKind, environment: [String: String],
                               timeout: TimeInterval = 15) async -> [String] {
        // Every task answers threads with `<cli> comments reply|status`.
        var comments = commandExists(cli: cli, arguments: ["comments", "reply", "--help"], timeout: timeout) ? [] : ["comments reply"]
        if !commandExists(cli: cli, arguments: ["secretary", "registry", "--help"], timeout: timeout) {
            comments.append("secretary registry")
        }
        guard let tools = await listTools(cli: cli, environment: environment, timeout: timeout) else {
            return comments + ["mcp (no answer from \(cli.path))"]
        }
        return comments + missing(tools: tools, kind: kind, pageLimit: MCPRecallServer.pageLimit(from: environment))
    }

    #if os(macOS)
    static func commandExists(cli: URL, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let deadline = stopAfterDeadline(process, timeout: timeout)
        defer { deadline.cancel() }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func listTools(cli: URL, environment: [String: String], timeout: TimeInterval) async -> [[String: Any]]? {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["mcp"]
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"wimm-secretary-check","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ]
        input.fileHandleForWriting.write(Data((requests.joined(separator: "\n") + "\n").utf8))
        let deadline = stopAfterDeadline(process, timeout: timeout)
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        do {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      (reply["id"] as? NSNumber)?.intValue == 2 else { continue }
                return (reply["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
            }
        } catch { return nil }
        return nil
    }
    /// Both probes are bounded, including a CLI that ignores SIGTERM.
    private static func stopAfterDeadline(_ process: Process, timeout: TimeInterval) -> Task<Void, Error> {
        Task.detached {
            try await Task.sleep(for: .seconds(timeout))
            guard process.isRunning else { return }
            process.terminate()
            try await Task.sleep(for: .milliseconds(250))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    #else
    // iOS cannot launch the external CLI. Fail the capability check closed.
    static func commandExists(cli: URL, arguments: [String], timeout: TimeInterval) -> Bool { false }
    static func listTools(cli: URL, environment: [String: String], timeout: TimeInterval) async -> [[String: Any]]? { nil }
    #endif

}
