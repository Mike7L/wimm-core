import Foundation
import WimmDomain

// MARK: - queue sub-commands

extension WimmTUIRuntime {

    static func runQueue(args: [String], container: AppContainer) async throws {
        guard let sub = args.first else {
            print("Usage: queue <process|status|retry|report>")
            return
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "process": try await runQueueProcess(args: rest, container: container)
        case "status":  try await runQueueStatus(args: rest, container: container)
        case "retry":   try await runQueueRetry(args: rest, container: container)
        case "report":  try await runQueueReport(args: rest, container: container)
        default:
            print("Usage: queue <process|status|retry|report>")
        }
    }

    // MARK: - queue process

    private static func runQueueProcess(args: [String], container: AppContainer) async throws {
        let opts = parseQueueProcessOptions(args: args)
        if opts.dryRun {
            let planned = try await container.queueSupervisor.previewProcessQueue(limit: opts.limit)
            print("Dry-run queue process\(opts.limit != nil ? " (limit: \(opts.limit!))" : ""):")
            print("  would process: \(planned.count)")
            if !planned.isEmpty {
                let ids = planned.prefix(20).map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")
                print("  ids: \(ids)")
            }
        } else {
            print("Processing queue\(opts.limit != nil ? " (limit: \(opts.limit!))" : "")...")
            let count = try await container.queueSupervisor.processQueue(limit: opts.limit)
            print("Processed \(count) notes.")
        }
    }

    // MARK: - queue status

    private static func runQueueStatus(args: [String], container: AppContainer) async throws {
        let snapshot = try await container.queueStatus.execute()
        print("Queue status:")
        print("  pending: \(snapshot.pendingCount)")
        print("  completed: \(snapshot.completedCount)")
        print("  failed.retryable: \(snapshot.failedRetryableCount)")
        print("  failed.non_retryable: \(snapshot.failedNonRetryableCount)")
        if ArgParser(args).flag("--details") {
            if snapshot.failedItems.isEmpty {
                print("  failed.details: none")
            } else {
                print("  failed.details:")
                for item in snapshot.failedItems.prefix(20) {
                    print("    [\(String(item.id.uuidString.prefix(8)))] retryable=\(item.retryable) reason=\(item.reason)")
                }
            }
        }
    }

    // MARK: - queue retry

    private static func runQueueRetry(args: [String], container: AppContainer) async throws {
        let opts = parseQueueRetryOptions(args: args)
        if opts.dryRun {
            let planned = try await container.queueSupervisor.previewRetryFailedTasks(
                includeNonRetryable: opts.includeAll,
                idPrefix: opts.idPrefix
            )
            print("Dry-run queue retry:")
            print("  would retry: \(planned.count)")
            if !planned.isEmpty {
                let ids = planned.prefix(20).map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")
                print("  ids: \(ids)")
            }
        } else {
            let result = try await container.queueSupervisor.retryFailedTasks(
                includeNonRetryable: opts.includeAll,
                idPrefix: opts.idPrefix
            )
            print("Retried \(result.retried) failed notes.")
            print("Processed \(result.processed) notes.")
        }
    }

    // MARK: - queue report

    private static func runQueueReport(args: [String], container: AppContainer) async throws {
        let opts = parseQueueReportOptions(args: args)
        let format: FailedReportFormat = opts.format == "csv" ? .csv : .md
        let report = try await container.failedReport.execute(format: format)
        let url = try writeReport(report, preferredPath: opts.outputPath, format: opts.format)
        print("Report exported: \(url.path)")
    }

    // MARK: - Parsing helpers

    struct QueueProcessOptions {
        var limit: Int? = nil
        var dryRun: Bool = false
    }

    struct QueueRetryOptions {
        var includeAll: Bool = false
        var idPrefix: String? = nil
        var dryRun: Bool = false
    }

    struct QueueReportOptions {
        var format: String = "md"
        var outputPath: String? = nil
    }

    static func parseQueueProcessOptions(args: [String]) -> QueueProcessOptions {
        let p = ArgParser(args)
        return QueueProcessOptions(limit: p.int("--limit"), dryRun: p.flag("--dry-run"))
    }

    static func parseQueueRetryOptions(args: [String]) -> QueueRetryOptions {
        let p = ArgParser(args)
        return QueueRetryOptions(
            includeAll: p.flag("--all"),
            idPrefix:   p.string("--id"),
            dryRun:     p.flag("--dry-run")
        )
    }

    static func parseQueueReportOptions(args: [String]) -> QueueReportOptions {
        let p = ArgParser(args)
        let fmt = p.string("--format").flatMap { ["md", "csv"].contains($0.lowercased()) ? $0.lowercased() : nil }
        return QueueReportOptions(format: fmt ?? "md", outputPath: p.string("--output"))
    }

    // MARK: - Report file writer

    static func writeReport(_ report: String, preferredPath: String?, format: String) throws -> URL {
        let fm = FileManager.default
        let filename = "queue_failed_report_\(timestamp()).\(format)"
        let outputURL: URL
        if let path = preferredPath, !path.isEmpty {
            outputURL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(path)
        } else {
            outputURL = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(filename)
        }
        try report.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}
