import ArgumentParser
import Foundation
import WimmInfrastructure

/// `wimm-cli mcp` — connects Wimm to an agent. Register it once, e.g.
/// `claude mcp add wimm -- /path/to/WimmCLI mcp`, and the agent can search
/// and read the library to answer basic questions, or save discussion as a
/// new Markdown note. Other writes are agent marks (`AgentState/`) and
/// retranscription requests, which a detached `transcript drain-queue`
/// worker runs through the ordinary transcription path.
struct MCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve the note library to an AI agent over MCP (stdio)"
    )

    func run() async throws {
        // Changed notes are built by `mcp-build` in a child process, so the
        // parsing garbage leaves with it instead of staying in this one.
        let mode: LibraryRecallSource.BuildMode = Bundle.main.executableURL.map {
            .subprocess(executable: $0, arguments: [MCPBuild.configuration.commandName!])
        } ?? .inProcess
        let library = LibraryRecallSource(buildMode: mode)
        // The library loads on the first tool call, not here: every agent
        // session starts its own server, and most never ask Wimm anything
        // (~150–190 MB each once loaded). After `idleSeconds` without a call
        // the text is dropped again; the next call reloads it (~3 s).
        let idleSeconds = Self.idleReleaseSeconds(from: ProcessInfo.processInfo.environment)
        if idleSeconds > 0 {
            Task.detached {
                while true {
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    await library.releaseIfIdle(after: idleSeconds)
                }
            }
        }
        // The client exiting normally closes stdin and ends `serveStdio`; a
        // client killed hard can leave the server reparented to launchd.
        let originalParent = getppid()
        Task.detached {
            while true {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                if getppid() != originalParent { Foundation.exit(0) }
            }
        }
        let startWorker: @Sendable () -> Void = {
            guard let executable = Bundle.main.executableURL else { return }
            Self.startDetachedWorker(executable: executable)
        }
        // Requests left over from a worker that died (or a Mac that slept) resume.
        if RetranscriptionQueue().hasQueued { startWorker() }
        let server = MCPRecallServer(startRetranscriptionWorker: startWorker,
                                     pageLimit: MCPRecallServer.pageLimit(from: ProcessInfo.processInfo.environment),
                                     readLog: ProcessInfo.processInfo.environment[MCPRecallServer.readLogEnvironmentKey].map { URL(fileURLWithPath: $0) },
                                     reviewConfiguration: ProcessInfo.processInfo.environment["WIMM_SECRETARY_REVIEW"],
                                     allowedTools: ProcessInfo.processInfo.environment[MCPRecallServer.toolsEnvironmentKey].map { Set($0.split(separator: ",").map(String.init)) },
                                     library: { await library.load() })
        await server.serveStdio()
    }

    /// `WIMM_MCP_IDLE_RELEASE_SECONDS`: 0 keeps the library for the server's
    /// life; default 600.
    static func idleReleaseSeconds(from environment: [String: String]) -> TimeInterval {
        environment["WIMM_MCP_IDLE_RELEASE_SECONDS"].flatMap(TimeInterval.init) ?? 600
    }

    /// Starts `transcript drain-queue` in a session of its own, through a shell
    /// that exits at once: the worker is reparented to launchd and outlives
    /// this server — and the agent session that would kill it. Its output goes
    /// to `AgentState/retranscription-worker.log`; stdout here is the protocol.
    static func startDetachedWorker(executable: URL) {
        let queue = RetranscriptionQueue()
        try? FileManager.default.createDirectory(at: queue.directory, withIntermediateDirectories: true)
        let logPath = queue.directory.appendingPathComponent("retranscription-worker.log").path
        func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "nohup \(quoted(executable.path)) transcript drain-queue </dev/null >>\(quoted(logPath)) 2>&1 &"

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/sh", "-c", command].map { (s: String) in strdup(s) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, environ) == 0 else {
            FileHandle.standardError.write(Data("mcp: could not start the retranscription worker\n".utf8))
            return
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

/// Child half of `mcp`: recording paths on stdin, built notes on stdout.
struct MCPBuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp-build",
        abstract: "Internal: build notes for the MCP server",
        shouldDisplay: false
    )

    @Flag(name: .long, help: "Include content fingerprints for secretary preparation")
    var fingerprints = false

    func run() async throws {
        await LibraryRecallSource.serveBuild(includeFingerprints: fingerprints)
    }
}
