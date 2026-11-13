import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes split-attachments`: one note = one media (2026-11-09),
/// stage 2 of `docs/One_Note_One_Media_Decision_2026-11-09.md`. Dry-run by
/// default; the dry run reads the library and writes only the JSON report
/// (outside the library unless `--report` says otherwise).
struct NotesSplitAttachments: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split-attachments",
        abstract: "Turn every sidecar attachment into a note of its own (dry-run unless --apply)"
    )

    @Flag(name: .long, help: "Move files and write sidecars. Without it nothing in the library changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Where to write the JSON report (default: the backup folder with --apply, a temp file otherwise)")
    var report: String?

    @Option(name: .long, parsing: .upToNextOption, help: "Only these parent sidecars (file names or paths)")
    var only: [String] = []

    @Option(name: .long, help: "Process at most this many parents")
    var limit: Int?

    @Flag(name: .long, help: "Apply even though Wimm or Wimm Studio is running (they may write the same sidecars)")
    var allowRunningApp: Bool = false

    func run() async throws {
        let library = StoragePaths.baseDirectory()
        if apply && !allowRunningApp && Self.desktopAppIsRunning() {
            print("Wimm or Wimm Studio is running. Quit it first (or pass --allow-running-app).")
            throw ExitCode.failure
        }
        let stamp = Self.stamp()
        let backup = apply
            ? library.appendingPathComponent("repair-backups/split-attachments-\(stamp)", isDirectory: true)
            : nil
        let options = AttachmentSplitMigration.Options(
            apply: apply,
            backupDirectory: backup,
            onlyParents: only.isEmpty ? nil : Set(only.map { ($0 as NSString).lastPathComponent }),
            limit: limit
        )
        let result = try AttachmentSplitMigration.run(options)

        let reportURL: URL
        if let report {
            reportURL = URL(fileURLWithPath: (report as NSString).expandingTildeInPath)
        } else if let backup {
            reportURL = backup.appendingPathComponent("report.json")
        } else {
            reportURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("split-attachments-dry-run-\(stamp).json")
        }
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: reportURL, options: .atomic)

        let t = result.totals
        print(apply ? "APPLIED to \(library.path)" : "DRY RUN (nothing changed) on \(library.path)")
        print("Sidecars scanned: \(t.sidecarsScanned); parse errors: \(t.parseErrors)")
        print("Parents with attachments: \(t.parentsWithAttachments); to change: \(t.parentsToChange); failed: \(t.parentsFailed)")
        print("Empty attachment lists: \(t.emptyLists)")
        print("Attachments: \(t.attachments)")
        for (title, counts) in [("By action", t.byAction), ("By kind", t.byKind), ("By source", t.bySource),
                                ("By parent kind", t.byParentKind), ("Link", t.byLink), ("Carried text", t.withText),
                                ("Left in place", t.leftInPlaceByExtension)] {
            let line = counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("\(title): \(line.isEmpty ? "-" : line)")
        }
        print("_micro moved: \(t.microMoved)")
        print("Report: \(reportURL.path)")
        if let backup { print("Backups: \(backup.path)") }
        if t.parentsFailed > 0 { throw ExitCode.failure }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    static func desktopAppIsRunning() -> Bool {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "/(Wimm|WimmStudio|Wimm Studio)\\.app/Contents/MacOS/"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
