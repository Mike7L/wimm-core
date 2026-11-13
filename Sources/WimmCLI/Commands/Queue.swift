import ArgumentParser
import WimmTUI
import Foundation

struct Queue: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage processing queues (Transcription & Analysis)"
    )

    @Flag(name: .long, help: "Run processing for all pending items")
    var process: Bool = false

    @Option(name: .shortAndLong, help: "Batch size for analysis")
    var batchSize: Int = 10

    @Flag(name: .long, help: "Process only analysis queue (skip transcription queue)")
    var analysisOnly: Bool = false

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Show detailed queue composition (type, priority, reason, file)"
    )
    var details: Bool = true

    mutating func run() async throws {
        if process {
            var args = ["queue", "process"]
            if batchSize > 0 {
                args.append(contentsOf: ["--limit", "\(batchSize)"])
            }
            if analysisOnly {
                print("Warning: --analysis-only is not yet supported by WIMM queue process; running full queue process.")
            }
            try await WimmTUIRuntime.runOnce(args)
            return
        }

        var args = ["queue", "status"]
        if details {
            args.append("--details")
        }
        try await WimmTUIRuntime.runOnce(args)
    }
}
