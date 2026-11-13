import ArgumentParser
import WimmTUI
import Foundation

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import files through the WIMM storage pipeline"
    )

    @Argument(help: "Input files or folders to import")
    var paths: [String] = []

    @Flag(name: .long, help: "Preview only: do not copy files")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Legacy option; currently ignored by WIMM import")
    var backfillText: Bool = false

    @Option(name: .long, help: "Legacy option; currently ignored by WIMM import")
    var maxPDFOCRPages: Int = 50

    @Flag(name: .long, help: "Legacy option; currently unsupported by WIMM import")
    var json: Bool = false

    func run() async throws {
        guard !paths.isEmpty else {
            throw ValidationError("Provide at least one input path.")
        }

        if json {
            print("Warning: --json is not supported by WIMM import; using text output.")
        }
        if backfillText {
            print("Warning: --backfill-text is not supported by WIMM import; ignoring.")
        }
        if maxPDFOCRPages != 50 {
            print("Warning: --max-pdf-ocr-pages is not supported by WIMM import; ignoring.")
        }

        var tuiArgs = ["import"]
        tuiArgs.append(contentsOf: paths)
        if dryRun {
            tuiArgs.append("--dry-run")
        }
        try await WimmTUIRuntime.runOnce(tuiArgs)
    }
}
