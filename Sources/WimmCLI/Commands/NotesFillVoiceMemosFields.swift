import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes fill-voicememos-fields --notes list.json`: adds the keys
/// `RecordingMetadata` needs (`recordingURL`, `isComplete`, `lastSaved`,
/// measured `duration`) to Voice Memos imports that had no earlier copy to
/// merge with. Only missing keys are written. Dry run unless `--apply`;
/// needs Wimm and Studio closed.
struct NotesFillVoiceMemosFields: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fill-voicememos-fields",
        abstract: "Add missing recordingURL/isComplete/lastSaved/duration to Voice Memos imports (dry-run unless --apply)"
    )

    @Option(name: .long, help: "JSON {notes:[media file name, …]}")
    var notes: String

    @Flag(name: .long, help: "Write. Without it nothing changes.")
    var apply: Bool = false

    @Option(name: .long, help: "Process only the first N notes that need fields")
    var limit: Int?

    @Flag(name: .long, help: "Apply even though Wimm or Wimm Studio is running")
    var allowRunningApp: Bool = false

    func run() async throws {
        if apply && !allowRunningApp && NotesSplitAttachments.desktopAppIsRunning() {
            print("Wimm or Wimm Studio is running. Quit it first (or pass --allow-running-app).")
            throw ExitCode.failure
        }
        let list = try VoiceMemosServiceFields.load(listAt: URL(fileURLWithPath: (notes as NSString).expandingTildeInPath))
        let library = FileStore.recordingsDirectory()
        let rows = VoiceMemosServiceFields.run(notes: list, directory: library, apply: apply, limit: limit)
        print(apply ? "APPLIED to \(library.path)" : "DRY RUN (nothing changed) on \(library.path)")
        var counts: [String: Int] = [:]
        for row in rows {
            let key: String
            switch row.outcome {
            case .wouldFill(let keys): key = "would fill \(keys.joined(separator: ","))"
            case .filled(let keys): key = "filled \(keys.joined(separator: ","))"
            case .complete: key = "already complete"
            case .skipped(let why): key = "skipped: \(why)"
            case .failed(let why): key = "FAILED: \(why)"
            }
            counts[key, default: 0] += 1
            let duration = row.duration.map { String(format: "%.2f s", $0) } ?? ""
            print("\(key)\t\(row.note)\t\(duration)")
        }
        for (key, n) in counts.sorted(by: { $0.key < $1.key }) { print("\(n)\t\(key)") }
        if rows.contains(where: { if case .failed = $0.outcome { return true } else { return false } }) {
            throw ExitCode.failure
        }
    }
}
