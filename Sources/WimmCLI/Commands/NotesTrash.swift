import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes trash`: moves the listed notes to Wimm's Trash (restorable, nothing
/// is deleted). Dry run unless `--apply`. iCloud learns about it from
/// `wimm-cli sync tombstone-trash --apply` afterwards.
struct NotesTrash: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "Move the listed notes to Wimm's Trash (dry-run unless --apply)"
    )

    @Argument(help: "Note file names in Recordings/ (e.g. Wimm_2026-11-15_03-14-11_B98F1BC3.aac)")
    var names: [String] = []

    @Option(name: .long, help: "Read note file names from this file, one per line")
    var filesFrom: String?

    @Flag(name: .long, help: "Move the notes. Without it nothing in the library changes.")
    var apply: Bool = false

    func run() async throws {
        var all = names
        if let filesFrom {
            let url = URL(fileURLWithPath: (filesFrom as NSString).expandingTildeInPath)
            all += try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        }
        let plan = NoteTrashBatch.plan(names: all)

        print(apply ? "APPLY on \(FileStore.recordingsDirectory().path)" : "DRY RUN (nothing changed) on \(FileStore.recordingsDirectory().path)")
        print("Notes to move to Trash: \(plan.notes.count)")
        for url in plan.notes { print("  \(url.lastPathComponent)") }
        for (name, reason) in plan.rejected { print("Rejected \(name): \(reason.rawValue)") }

        guard plan.rejected.isEmpty else {
            print("Fix the rejected names first; nothing was moved.")
            throw ExitCode.failure
        }
        guard apply else {
            print("Re-run with --apply to move \(plan.notes.count) notes to Trash.")
            return
        }
        if isLibraryAppRunning() {
            print("Quit Wimm / Wimm Studio first.")
            throw ExitCode.failure
        }
        let result = NoteTrashBatch.apply(plan)
        print("Moved to Trash: \(result.trashed.count); failed: \(result.failed.count)")
        for name in result.failed { print("  failed: \(name)") }
        print("Next: wimm-cli sync tombstone-trash --apply, so other devices drop them too.")
        if !result.failed.isEmpty { throw ExitCode.failure }
    }
}
