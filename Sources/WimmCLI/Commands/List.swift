import ArgumentParser
import WimmTUI
import Foundation

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recent notes")

    @Option(name: .shortAndLong, help: "Number of notes to list")
    var limit: Int = 10

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        var tuiArgs = ["list", "--limit", "\(max(0, limit))"]
        if json { tuiArgs.append("--json") }
        try await WimmTUIRuntime.runOnce(tuiArgs)
    }
}

