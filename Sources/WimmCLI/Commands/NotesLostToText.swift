import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes lost-to-text`: notes whose media is gone but whose text
/// survives in the sidecar become plain `{base}.txt` notes with a header
/// line (`docs/Note_Content_Resolver_Design_2026-11-10.md`). Dry run by
/// default: reads the library and writes only the report to `logs/`.
/// `--apply` creates `{base}.txt` files and nothing else — no sidecar write,
/// no overwrite. Also the detector after any cleanup: a non-empty candidate
/// list means something was lost.
struct NotesLostToText: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lost-to-text",
        abstract: "Turn sidecars whose media is lost into plain .txt notes (dry-run unless --apply)"
    )

    @Flag(name: .long, help: "Create the {base}.txt files. Without it nothing in the library changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Where to write the Markdown report (default: <library>/logs/lost-to-text-<date>.md)")
    var report: String?

    @Flag(name: .long, help: "Apply even though Wimm or Wimm Studio is running")
    var allowRunningApp: Bool = false

    func run() async throws {
        let library = StoragePaths.baseDirectory()
        if apply && !allowRunningApp && NotesSplitAttachments.desktopAppIsRunning() {
            print("Wimm or Wimm Studio is running. Quit it first (or pass --allow-running-app).")
            throw ExitCode.failure
        }
        var result = LostMediaToText.scan()
        if apply { result = LostMediaToText.apply(result) }

        let stamp: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return f.string(from: Date())
        }()
        let reportURL = report.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? library.appendingPathComponent("logs/lost-to-text-\(stamp)\(apply ? "-apply" : "").md")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LostMediaToText.markdown(result, applied: apply, library: library)
            .write(to: reportURL, atomically: true, encoding: .utf8)

        print(apply ? "APPLIED to \(library.path)" : "DRY RUN (nothing changed) on \(library.path)")
        print("Sidecars scanned: \(result.sidecarsScanned); parse errors: \(result.parseErrors.count)")
        print("base\tduration\twords\tlinks\theader")
        for row in result.candidates {
            print("\(row.base)\t\(row.durationSec.map { String(Int($0.rounded())) + "s" } ?? "-")\t\(row.words)\t\(row.links)\t\(row.header)")
        }
        let words = result.candidates.reduce(0) { $0 + $1.words }
        let known = result.candidates.filter { $0.durationSec != nil }
        let hours = known.reduce(0.0) { $0 + ($1.durationSec ?? 0) } / 3600
        print("Candidates: \(result.candidates.count), \(words) words; known duration \(known.count) (\(String(format: "%.1f", hours)) h); "
              + "with incoming links \(result.candidates.filter { $0.links > 0 }.count)")
        for reason in LostMediaToText.Skipped.Reason.allCases {
            let rows = result.skipped.filter { $0.reason == reason }
            print("Not converted, \(reason.rawValue): \(rows.count) (\(rows.reduce(0) { $0 + $1.words }) words)")
        }
        if apply { print("Created: \(result.created.count); refused (file exists): \(result.refused.count)") }
        print("Report: \(reportURL.path)")
        if apply && !result.refused.isEmpty { throw ExitCode.failure }
    }
}
