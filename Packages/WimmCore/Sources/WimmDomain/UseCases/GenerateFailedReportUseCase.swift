import Foundation

public enum FailedReportFormat: String, Sendable {
    case md
    case csv
}

public struct GenerateFailedReportUseCase: Sendable {
    private let queueStatus: GetQueueStatusUseCase

    public init(storage: StoragePort) {
        self.queueStatus = GetQueueStatusUseCase(storage: storage)
    }

    public func execute(format: FailedReportFormat) async throws -> String {
        let snapshot = try await queueStatus.execute()
        switch format {
        case .md:
            return buildMarkdown(snapshot: snapshot)
        case .csv:
            return buildCSV(snapshot: snapshot)
        }
    }

    private func buildMarkdown(snapshot: QueueStatusSnapshot) -> String {
        var lines = ["# Failed Queue Report", ""]
        lines.append("Generated at: \(ISO8601.string(from: Date()))")
        lines.append("Pending: \(snapshot.pendingCount)")
        lines.append("Completed: \(snapshot.completedCount)")
        lines.append("Failed retryable: \(snapshot.failedRetryableCount)")
        lines.append("Failed non-retryable: \(snapshot.failedNonRetryableCount)")
        lines.append("")

        if snapshot.failedItems.isEmpty {
            lines.append("No failed notes.")
            return lines.joined(separator: "\n")
        }

        for item in snapshot.failedItems {
            lines.append("## \(item.id.uuidString)")
            lines.append("- created: \(ISO8601.string(from: item.createdAt))")
            lines.append("- retryable: \(item.retryable)")
            lines.append("- reason: \(item.reason)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private func buildCSV(snapshot: QueueStatusSnapshot) -> String {
        var lines = ["id,created_at,retryable,reason"]
        for item in snapshot.failedItems {
            let created = ISO8601.string(from: item.createdAt)
            lines.append("\(item.id.uuidString),\(created),\(item.retryable),\(csvEscape(item.reason))")
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
