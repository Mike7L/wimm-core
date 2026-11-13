import Foundation
import WimmInfrastructure

/// One invocation, monotonic stage durations. Contains no evidence or provider usage.
final class SecretaryFileTiming {
    private let started = DispatchTime.now().uptimeNanoseconds
    private var previous = DispatchTime.now().uptimeNanoseconds
    private var stages: [String: Double] = [:]
    private var counts: [String: Int] = [:]
    private var outcome = "failed"
    let operation: String

    init(_ operation: String) { self.operation = operation }

    func checkpoint(_ name: String, subtotal: String? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now - previous) / 1_000_000
        stages[name, default: 0] += elapsed
        if let subtotal { stages[subtotal, default: 0] += elapsed }
        previous = now
    }

    func count(_ name: String, _ value: Int) { counts[name, default: 0] += value }

    func finish(_ data: Data) throws -> Data {
        checkpoint("report")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        outcome = (object["findings"] as? [String])?.isEmpty == false ? "findings" : "succeeded"
        object["timings_ms"] = durations()
        object["work_counts"] = counts
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    func replayed() { outcome = "replayed"; checkpoint("replay") }

    private func durations() -> [String: Double] {
        var result = stages
        result["total"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        return result
    }

    /// Separate files avoid append races. Diagnostics must not fail a valid commit.
    func write(runID: String, marks: AgentMarkStore) {
        guard runID.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,100}$"#, options: .regularExpression) != nil else { return }
        let directory = marks.directory.appendingPathComponent("SecretaryFileSessions/\(runID).timings")
        let object: [String: Any] = ["operation": operation, "outcome": outcome,
            "recorded_at": ISO8601DateFormatter().string(from: Date()),
            "timings_ms": durations(), "work_counts": counts]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch { /* Timing is diagnostic; authoritative run state has its own error path. */ }
    }
}
