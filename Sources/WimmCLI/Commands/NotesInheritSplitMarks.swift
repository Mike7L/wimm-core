import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes inherit-split-marks`: notes split off by `split-attachments`
/// take their parent's settled secretary mark, so text the secretary already read
/// inside the parent is not offered again. Dry-run by default; writes marks only.
struct NotesInheritSplitMarks: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inherit-split-marks",
        abstract: "Give split-off attachment notes their parent's applied/noise mark (dry-run unless --apply)"
    )

    @Flag(name: .long, help: "Write the marks. Without it nothing changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Where to write the JSON report (default: a temp file)")
    var report: String?

    func run() async throws {
        let library = StoragePaths.baseDirectory()
        let result = try SplitMarkInheritance.run(library: library, apply: apply)
        let reportURL = report.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inherit-split-marks-\(Int(Date().timeIntervalSince1970)).json")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: reportURL, options: .atomic)

        print(apply ? "APPLIED to \(library.path)" : "DRY RUN (nothing changed) on \(library.path)")
        print("Split notes: \(result.items.count)")
        for (key, count) in result.byAction.sorted(by: { $0.value > $1.value }) { print("  \(key): \(count)") }
        let statuses = result.inheritedStatus.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("Inherited status: \(statuses.isEmpty ? "-" : statuses)")
        print("Report: \(reportURL.path)")
    }
}
