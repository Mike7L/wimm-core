import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure
import WimmSecretary

/// `wimm-cli notes merge-voicememos-duplicates --pairs pairs.json --workspace ~/Projects/_ME`:
/// an imported Voice Memo takes over the analysis of the earlier iPhone import
/// of the same recording (marks, `_ME` registry and `[S…]:` definitions follow),
/// then the old note goes to Trash. Dry run by default; needs Wimm and Studio
/// closed. The cloud tombstone is a separate, existing step (printed at the end).
struct NotesMergeVoiceMemosDuplicates: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-voicememos-duplicates",
        abstract: "Move analysis from old iPhone-import notes to Voice Memos imports and trash the old ones (dry-run unless --apply)"
    )

    @Option(name: .long, help: "Pairs JSON ({pairs:[{old,new,twins?:[…]}]}); twins are other 19.10 copies of the same sound")
    var pairs: String

    @Option(name: .long, help: "Secretary workspace root (_ME). Required with --apply.")
    var workspace: String?

    @Flag(name: .long, help: "Write. Without it nothing changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Process only the first N eligible pairs")
    var limit: Int?

    @Flag(name: .long, help: "Apply even though Wimm or Wimm Studio is running")
    var allowRunningApp: Bool = false

    func run() async throws {
        if apply && !allowRunningApp && NotesSplitAttachments.desktopAppIsRunning() {
            print("Wimm or Wimm Studio is running. Quit it first (or pass --allow-running-app).")
            throw ExitCode.failure
        }
        if apply && workspace == nil { throw ValidationError("--workspace is required with --apply.") }
        let loaded = try VoiceMemosMerge.load(pairsAt: URL(fileURLWithPath: (pairs as NSString).expandingTildeInPath))
        let options = VoiceMemosMerge.Options(
            workspace: workspace.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            backupDirectory: StoragePaths.baseDirectory().appendingPathComponent("repair-backups", isDirectory: true),
            apply: apply, limit: limit)
        let rows = VoiceMemosMerge.run(pairs: loaded, options: options)

        print(apply ? "APPLIED" : "DRY RUN (nothing changed)")
        var counts: [String: Int] = [:]
        for row in rows {
            let key: String
            switch row.outcome {
            case .wouldMerge: key = "would merge"
            case .merged: key = "merged"
            case .alreadyDone: key = "already done"
            case .skipped(let why): key = "skipped: \(why)"
            case .failed(let why): key = "FAILED: \(why)"
            }
            counts[key, default: 0] += 1
            switch row.outcome {
            case .skipped, .failed: print("\(key)\t\(row.pair.old) -> \(row.pair.new)")
            default:
                if !(row.pair.twins ?? []).isEmpty {
                    let twins = zip(row.pair.twins ?? [], row.twinSources + Array(repeating: "-", count: 8)).map { "\($0) (\($1))" }
                    print("\(key)\t\(row.source ?? "-") \(row.pair.old) + \(twins.joined(separator: ", ")) -> \(row.pair.new)")
                }
            }
        }
        for (key, n) in counts.sorted(by: { $0.key < $1.key }) { print("\(n)\t\(key)") }
        if apply, rows.contains(where: { $0.outcome == .merged }) {
            print("Next: close nothing else, then queue cloud tombstones for the trashed notes:")
            print("  wimm-cli sync tombstone-trash --apply --from-log <backup>/trash_log.json")
        }
        if apply {
            print("The trash log is written after every pair. If a run was interrupted, rerun the same")
            print("command with --apply: already merged pairs are logged again from Trash.")
        }
        if rows.contains(where: { if case .failed = $0.outcome { return true } else { return false } }) {
            throw ExitCode.failure
        }
    }
}
