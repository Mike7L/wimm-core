import Foundation

/// Read-only view of a finished run directory (`secretary/runs/<id>/`): what
/// Wimm recorded, how much it cost and whether the run left a consistent
/// trail. No model, no marks, no writes (`wimm-cli secretary log|check`).
public struct SecretaryRunLog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var record: SecretaryRunRecord?
        /// Files in the run directory, sorted.
        public var files: [String]
        public var problems: [String]
    }

    public static let idPattern = #"^\d{8}-\d{6}-[a-f0-9]{4}$"#

    /// Run ids of a workspace, oldest first.
    public static func runIDs(in workspace: SecretaryWorkspace) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workspace.runsDirectory.path)) ?? []
        return names.filter { $0.range(of: idPattern, options: .regularExpression) != nil }.sorted()
    }

    /// Reads one run. Never throws: a broken run is reported in `problems`.
    public static func entry(id: String, in workspace: SecretaryWorkspace) -> Entry {
        let dir = workspace.runDirectory(id)
        let files = ((try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var problems: [String] = []
        func has(_ name: String) -> Bool { files.contains(name) }

        var record: SecretaryRunRecord?
        if let data = try? Data(contentsOf: dir.appendingPathComponent("run.json")) {
            record = try? JSONDecoder().decode(SecretaryRunRecord.self, from: data)
            if record == nil { problems.append("run.json does not decode") }
        } else {
            problems.append("run.json missing")
        }
        if record?.workflow == "file-packet" {
            if !has("export/manifest.json") { problems.append("file-packet manifest missing") }
        } else if !has("task.md") { problems.append("task.md missing") }

        if let record {
            if record.id != id { problems.append("run.json id \(record.id) differs from folder \(id)") }
            if record.outcome == nil { problems.append("run never finished (no outcome)") }
            if record.outcome == .succeeded {
                if !record.findings.isEmpty { problems.append("succeeded with \(record.findings.count) finding(s)") }
                if record.error != nil { problems.append("succeeded but has an error") }
            }
            // `incomplete` is the normal end of a clean packet while notes still wait.
            if record.outcome != .succeeded, record.outcome != .incomplete, record.error == nil, record.findings.isEmpty, record.outcome != nil {
                problems.append("\(record.outcome!.rawValue) without error or finding")
            }
            if record.workflow == "packet" {
                if !has("packet-execution.json") { problems.append("packet run without packet-execution.json") }
                else if let data = try? Data(contentsOf: dir.appendingPathComponent("packet-execution.json")) {
                    if let exec = try? JSONDecoder().decode(SecretaryExecution.self, from: data) {
                        if exec.finalText == nil { problems.append("packet-execution.json has no final text") }
                        if exec.costUSD == nil && exec.tokensIn == nil { problems.append("usage unknown (not zero)") }
                    } else {
                        problems.append("packet-execution.json does not decode")
                    }
                }
            }
        }
        return Entry(id: id, record: record, files: files, problems: problems)
    }

    /// One line per run for `log --list`.
    public static func summaryLine(_ entry: Entry) -> String {
        guard let r = entry.record else { return "\(entry.id)  (unreadable)" }
        let cost = r.costUSD.map { String(format: "$%.4f", $0) } ?? "cost ?"
        let tokens = "\(r.tokensIn.map(String.init) ?? "?")/\(r.tokensOut.map(String.init) ?? "?") tok"
        let flag = entry.problems.isEmpty ? "" : "  ⚠︎ \(entry.problems.count)"
        return "\(entry.id)  \(r.kind.rawValue)  \(r.outcome?.rawValue ?? "unfinished")  \(r.executor)\(r.model.map { "/" + $0 } ?? "")  \(cost)  \(tokens)\(flag)"
    }

    /// `time 14m02s: model_round_1 12m40s (90%), …` — slowest stage first, with the share
    /// spent waiting for the editor. Nil for runs recorded before timings existed.
    public static func timingLine(_ timings: [String: Double]?) -> String? {
        guard let timings, let total = timings["total"], total > 0 else { return nil }
        func span(_ ms: Double) -> String {
            let seconds = ms / 1000
            if seconds < 10 { return String(format: "%.1fs", seconds) }
            if seconds < 60 { return "\(Int(seconds.rounded()))s" }
            return String(format: "%dm%02ds", Int(seconds) / 60, Int(seconds) % 60)
        }
        let stages = timings.filter { $0.key != "total" }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let model = stages.filter { $0.key.hasPrefix("model_") }.reduce(0) { $0 + $1.value }
        let parts = stages.map { "\($0.key) \(span($0.value)) (\(Int(($0.value / total * 100).rounded()))%)" }
        return "time \(span(total)), model wait \(Int((model / total * 100).rounded()))%: " + parts.joined(separator: ", ")
    }

    /// Full report for `log <run>`.
    public static func report(_ entry: Entry) -> String {
        var out = [summaryLine(entry)]
        if let r = entry.record {
            out.append("  started \(r.startedAt)  finished \(r.finishedAt ?? "—")  workflow \(r.workflow ?? "agent")  turns \(r.turns.map(String.init) ?? "?")")
            if let line = timingLine(r.timingsMS) { out.append("  " + line) }
            if let remaining = r.remainingNotes { out.append("  notes remaining: \(remaining)") }
            if let summary = r.result?.summary { out.append("  summary: \(summary)") }
            if let error = r.error { out.append("  error: \(error)") }
            for f in r.findings { out.append("  finding: \(f)") }
            if let b = r.bookkeeping { out.append("  registry updated: \(b.registryUpdated.map(String.init) ?? "?")") }
        }
        out.append("  files: " + (entry.files.isEmpty ? "none" : entry.files.joined(separator: ", ")))
        for p in entry.problems { out.append("  problem: \(p)") }
        return out.joined(separator: "\n")
    }
}
