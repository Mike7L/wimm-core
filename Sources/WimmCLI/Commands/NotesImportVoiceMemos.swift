import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes import-voicememos --plan plan.json`: copies Apple Voice
/// Memos into the library under their real record dates, without transcription.
/// Dry run by default; `--apply` writes. `--limit N` imports only the first N
/// importable items (pilot). Needs Wimm and Studio closed.
struct NotesImportVoiceMemos: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-voicememos",
        abstract: "Import Voice Memos from a reviewed plan file (dry-run unless --apply)"
    )

    @Option(name: .long, help: "Plan JSON ({sourceDir, items:[{src,dst,timestamp,…}]})")
    var plan: String

    @Flag(name: .long, help: "Copy the files and write sidecars. Without it nothing changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Process only the first N importable items")
    var limit: Int?

    @Flag(name: .long, help: "Apply even though Wimm or Wimm Studio is running")
    var allowRunningApp: Bool = false

    func run() async throws {
        if apply && !allowRunningApp && NotesSplitAttachments.desktopAppIsRunning() {
            print("Wimm or Wimm Studio is running. Quit it first (or pass --allow-running-app).")
            throw ExitCode.failure
        }
        let planURL = URL(fileURLWithPath: (plan as NSString).expandingTildeInPath)
        let loaded = try VoiceMemosImport.load(planAt: planURL)
        let library = FileStore.recordingsDirectory()
        let rows = VoiceMemosImport.run(plan: loaded, destination: library, apply: apply, limit: limit)

        print(apply ? "APPLIED to \(library.path)" : "DRY RUN (nothing changed) on \(library.path)")
        var counts: [String: Int] = [:]
        for row in rows {
            let key: String
            switch row.outcome {
            case .wouldImport: key = "would import"
            case .imported: key = "imported"
            case .skipped(let why): key = "skipped: \(why)"
            case .failed(let why): key = "FAILED: \(why)"
            }
            counts[key, default: 0] += 1
            if case .skipped = row.outcome { print("\(key)\t\(row.item.src)") }
            if case .failed = row.outcome { print("\(key)\t\(row.item.src)") }
        }
        for (key, n) in counts.sorted(by: { $0.key < $1.key }) { print("\(n)\t\(key)") }
        if rows.contains(where: { if case .failed = $0.outcome { return true } else { return false } }) {
            throw ExitCode.failure
        }
    }
}
