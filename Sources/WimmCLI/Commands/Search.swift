import ArgumentParser
import WimmTUI
import Foundation

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Search notes")

    @Argument(help: "Query string")
    var query: String

    @Option(name: .shortAndLong, help: "Search scope (all, title, summary, content, project)")
    var scope: String = "all"

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        if scope.lowercased() != "all" {
            print("Warning: --scope \(scope) is not supported by WIMM search; searching all fields.")
        }
        var tuiArgs = ["search", "--text", query]
        if json { tuiArgs.append("--json") }
        try await WimmTUIRuntime.runOnce(tuiArgs)
    }
}
