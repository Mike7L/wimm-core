import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Manage iCloud recording sync",
        subcommands: [
            Backfill.self,
            TombstoneTrash.self,
        ]
    )

    struct Backfill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "backfill",
            abstract: "Queue existing recordings for iCloud sync"
        )

        @Flag(name: .long, help: "Preview without writing sync ids or queue state")
        var dryRun: Bool = false

        @Option(name: .long, help: "Maximum recordings to scan into this batch")
        var limit: Int?

        @Flag(name: .long, help: "Continue from current sync state")
        var resume: Bool = false

        @Option(name: .long, help: "Only consider files modified on or after YYYY-MM-DD")
        var since: String?

        @Flag(
            name: .long,
            inversion: .prefixedNo,
            help: "Only include recordings that do not already have syncId"
        )
        var onlyMissingSyncId: Bool = true

        @Option(name: .long, help: "Maximum batch size; defaults to 50")
        var batchSize: Int = 50

        mutating func run() async throws {
            let parsedSince = try parseSinceDate(since)
            let service = RecordingSyncBackfillService()
            let summary = await service.run(options: RecordingSyncBackfillOptions(
                dryRun: dryRun,
                limit: limit,
                since: parsedSince,
                onlyMissingSyncID: onlyMissingSyncId,
                batchSize: max(1, batchSize)
            ))

            print("Sync backfill \(dryRun ? "dry-run" : "queue")")
            print("Scanned: \(summary.scanned)")
            print("Eligible: \(summary.eligible)")
            print("Enqueued: \(summary.enqueued)")
            print("Skipped: \(summary.skipped)")
            print("Failed: \(summary.failed)")
            print("Total bytes: \(summary.totalBytes)")

            if !summary.failures.isEmpty {
                print("Failures:")
                for failure in summary.failures.prefix(20) {
                    print("- \(failure)")
                }
                if summary.failures.count > 20 {
                    print("- ... \(summary.failures.count - 20) more")
                }
            }

            guard !dryRun else { return }
            guard let syncService = CloudRecordingSyncService.live() else {
                print("CloudKit unavailable; recordings were queued locally.")
                return
            }

            do {
                try await syncService.uploadPending()
                print("Upload attempted for pending sync queue.")
            } catch {
                print("Upload failed: \(error)")
            }

            if resume {
                print("Resume mode used current local sync state.")
            }
        }

        private func parseSinceDate(_ raw: String?) throws -> Date? {
            guard let raw, !raw.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            guard let date = formatter.date(from: raw) else {
                throw ValidationError("--since must use YYYY-MM-DD")
            }
            return date
        }
    }
    /// Sends cloud tombstones for notes that sit in the Mac's Trash but were
    /// deleted before Mac deletes reached iCloud (fixed 2026-11-09).
    struct TombstoneTrash: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "tombstone-trash",
            abstract: "Mark notes in Trash as deleted in iCloud (dry-run unless --apply)"
        )

        @Flag(name: .long, help: "Queue the tombstones in the sync ledger and send them to iCloud")
        var apply: Bool = false

        @Option(name: .long, help: "Only notes named in this trash move log (JSON list of [from, to] pairs)")
        var fromLog: String?

        @Flag(name: .long, help: "List every note that would be marked")
        var verbose: Bool = false

        mutating func run() async throws {
            let names = try fromLog.map { try TrashTombstoneBackfill.trashedNames(fromLog: URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)) }
            let store = SyncStateStore()
            try await store.validatePersistence()
            let plan = TrashTombstoneBackfill.plan(ledger: await store.snapshot(), onlyNames: names)

            print("Trash tombstones \(apply ? "APPLY" : "dry-run")")
            print("Trash: \(FileStore.trashDirectory().path)")
            print("Notes in Trash scanned: \(plan.scanned)")
            print("Would mark deleted in iCloud: \(plan.items.count)")
            for (status, count) in plan.byLedgerStatus.sorted(by: { $0.key < $1.key }) {
                print("  ledger \(status): \(count)")
            }
            for reason in TrashTombstoneBackfill.SkipReason.allCases {
                let urls = plan.skipped[reason] ?? []
                guard !urls.isEmpty else { continue }
                print("Skipped \(reason.rawValue): \(urls.count)")
                if reason == .aliveInRecordings {
                    for url in urls.prefix(20) { print("  - \(url.lastPathComponent)") }
                }
            }
            if verbose {
                for item in plan.items {
                    print("  \(item.syncId.rawValue)  \(item.trashedURL.lastPathComponent)")
                }
            }

            guard apply else {
                print("Nothing written. Re-run with --apply to send \(plan.items.count) tombstones.")
                return
            }
            guard !plan.items.isEmpty else { return }
            // The ledger has one writer at a time: run with Wimm and Studio quit.
            if isLibraryAppRunning() {
                print("Quit Wimm / Wimm Studio first: they write the same sync ledger.")
                throw ExitCode.failure
            }
            guard let service = CloudRecordingSyncService.live() else {
                // A CLI cannot carry the CloudKit entitlement (macOS kills it
                // without the app's profile), so only the app can send. Queue
                // the tombstones; Wimm/Studio send them on their next sync.
                // Only a build that knows `pendingDelete` can read the ledger.
                try await store.enqueueDeletions(plan.items.map { ($0.syncId, $0.originalURL) })
                print("CloudKit is not available to the CLI. Queued \(plan.items.count) tombstones in the sync ledger;")
                print("Wimm/Studio built with pendingDelete support send them on their next sync.")
                return
            }
            let result = try await service.markDeleted(plan.items.map { ($0.syncId, $0.originalURL) })
            print("Queued \(plan.items.count); sent \(result.sent), failed \(result.failed) (failed ones stay queued for the next sync)")
        }
    }
}

/// Wimm (`Wimm`) or Studio (`wimm-studio`) is running; `pgrep` keeps AppKit out of the CLI.
func isLibraryAppRunning() -> Bool {
    for name in ["Wimm", "wimm-studio"] {
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { continue }
        process.waitUntilExit()
        if process.terminationStatus == 0 { return true }
    }
    return false
}
