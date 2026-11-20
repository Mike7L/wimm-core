import ArgumentParser
import Darwin
import Foundation
import WimmInfrastructure

/// `wimm-cli inbox --hook` — for the Claude Code `UserPromptSubmit` hook
/// (`docs/Agent_Inbox_Hook.md`): a few lines on what changed in the notes
/// since this agent session last looked, or nothing at all. Read-only over
/// the library; its own cursor per reader, unrelated to the secretary's pass
/// boundary and marks. No model call.
struct Inbox: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Print what changed in the notes since this reader last looked (agent hook)"
    )

    @Flag(name: .long, help: "Hook mode: read the hook JSON on stdin, stay silent on any problem, always exit 0")
    var hook = false

    @Option(name: .long, help: "Reader id for the read cursor (default: WIMM_INBOX_READER, CLAUDE_CODE_SESSION_ID, then session_id from the hook JSON)")
    var reader: String?

    /// A hook must never hold the user's turn: past this the process leaves
    /// with nothing printed and the cursor where it was.
    static let hookDeadlineSeconds = 3.0

    func run() async throws {
        // A closed pipe is a failed write (cursor stays), not a signal death.
        signal(SIGPIPE, SIG_IGN)
        let environment = ProcessInfo.processInfo.environment
        var input = Data()
        if hook {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.hookDeadlineSeconds) { Darwin.exit(0) }
            if isatty(STDIN_FILENO) == 0 { input = FileHandle.standardInput.readDataToEndOfFile() }
        }
        let id = AgentInbox.reader(explicit: reader, environment: environment, hookInput: input) ?? (hook ? nil : "cli")
        let outcome = await AgentInbox.run(reader: id) { text in
            try Self.writeAll(Data(text.utf8), to: STDOUT_FILENO)
        }
        guard !hook else { return }
        switch outcome {
        case .nothingNew: print("Nothing new.")
        case .privateMode: print("Wimm is in private mode: note text is not shared with agents.")
        case .outputFailed, .noReader, .reported: break
        }
    }

    /// Unbuffered, so "written" means the bytes left this process.
    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
    }
}
