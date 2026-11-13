import ArgumentParser
import WimmTUI

struct TUI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Run WIMM (Where Is My Mind) TUI"
    )

    @Argument(
        parsing: .captureForPassthrough,
        help: "Arguments forwarded to wimm-tui (for example: queue status --details)"
    )
    var passthrough: [String] = []

    @Flag(name: .long, help: "Print the launch command without running it")
    var dryRun: Bool = false

    mutating func run() async throws {
        if dryRun {
            var command = ["swift", "run", "--package-path", ".", "wimm-tui"]
            command.append(contentsOf: passthrough)
            print(command.joined(separator: " "))
            return
        }

        try await WimmTUIRuntime.runOnce(passthrough)
    }
}
