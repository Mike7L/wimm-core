import Foundation
import WimmInfrastructure

/// Mechanical changes to reviewed rows. All unowned fields and untouched rows survive.
enum SecretaryRegistryRevision {
    static let snapshotName = "registry-before-agent.json.lzfse"

    static func snapshot(_ data: Data, directory: URL) throws {
        let compressed = try (data as NSData).compressed(using: .lzfse)
        try (compressed as Data).write(to: directory.appendingPathComponent(snapshotName), options: .atomic)
    }

    struct Snapshot {
        let root: [String: Any]
        let sources: [String: [String: Any]]
    }
    static func originalRegistry(directory: URL) throws -> Snapshot? {
        let url = directory.appendingPathComponent(snapshotName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try (Data(contentsOf: url) as NSData).decompressed(using: .lzfse)
        guard let root = try JSONSerialization.jsonObject(with: data as Data) as? [String: Any],
              let sources = root["sources"] as? [[String: Any]] else { throw Failure("Invalid registry snapshot.") }
        var result: [String: [String: Any]] = [:]
        for source in sources {
            guard let id = source["source_id"] as? String, result[id] == nil else { throw Failure("Duplicate source in registry snapshot.") }
            result[id] = source
        }
        return Snapshot(root: root, sources: result)
    }

    static func validate(snapshot: Snapshot, current: [String: Any], sources: [String: [String: Any]], runID: String) throws {
        for (id, before) in snapshot.sources {
            guard let after = sources[id] else { throw Failure("\(id): source removed during the agent run.") }
            if !equal(before, after), (after["host_review"] as? [String: Any])?["run_id"] as? String != runID {
                throw Failure("\(id): existing registry row was edited during the agent run; use source_decisions.")
            }
        }
        let writable = Set(["sources", "counts", "source_count", "updated_on", "period_end", "batches", "supplementary_context", "wiki_integration"])
        for (key, value) in snapshot.root where !writable.contains(key) {
            guard let after = current[key], NSDictionary(dictionary: ["value": value]).isEqual(to: ["value": after]) else {
                throw Failure("Registry metadata \(key) was edited during the agent run.")
            }
        }
        if let before = snapshot.root["batches"] as? [Any] {
            guard let after = current["batches"] as? [Any], after.count >= before.count,
                  NSArray(array: before).isEqual(to: Array(after.prefix(before.count))) else {
                throw Failure("Registry history was rewritten during the agent run.")
            }
        }
    }

    static func revised(_ source: [String: Any], decision: SecretaryResult.SourceDecision,
                        receipt: SecretaryReadReceipt, task: SecretaryTask, known: Set<String>) throws -> [String: Any] {
        let valid = ["applied", "duplicate", "noise", "pending", "failed"]
        guard valid.contains(decision.status), !decision.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decision.reason.count <= 4000 else { throw Failure("\(decision.source): invalid status/reason in source_decisions.") }
        if let targets = decision.mergedWith {
            guard targets.count <= 100, Set(targets).count == targets.count,
                  targets.allSatisfy({ known.contains($0) && $0 != decision.source }) else {
                throw Failure("\(decision.source): invalid duplicate targets.")
            }
        }
        // A triage preview can only say "not a note".
        if receipt.partialView != nil, decision.status != "noise" {
            throw Failure("\(decision.source): a partial view of the source can only be marked noise.")
        }
        var row = source
        row["status"] = decision.status; row["reason"] = decision.reason
        if decision.status == "duplicate" {
            if let targets = decision.mergedWith, !targets.isEmpty {
                row["merged_with"] = targets; row.removeValue(forKey: "duplicate_of")
            }
            let target = row["duplicate_of"] ?? row["merged_with"]
            let targets = (target as? [String]) ?? (target as? String).map { [$0] } ?? []
            guard !targets.isEmpty, targets.allSatisfy({ known.contains($0) && $0 != decision.source }) else {
                throw Failure("\(decision.source): duplicate needs valid merged_with source IDs.")
            }
        } else if source["status"] as? String == "duplicate" {
            row.removeValue(forKey: "duplicate_of"); row.removeValue(forKey: "merged_with")
        }
        // A retry of the same finalization must not create another historical revision.
        let prior = source["host_review"] as? [String: Any]
        if prior?["run_id"] as? String == task.id,
           equal(row, source), source["sha256"] as? String == receipt.sha256 { return source }
        row["sha256"] = receipt.sha256; row["read_sha256"] = receipt.sha256
        row["reviewed_on"] = day(task.createdAt)
        row["primary_text_read"] = receipt.wholeTextSupplied
        row["read_scope"] = receipt.partialView != nil ? "partial_view" : receipt.allAvailableTextSupplied ? "all_available_text_recheck"
            : (receipt.suppliedText == nil ? "version_only" : "partial_text_recheck")
        if let local = receipt.localVariantSupplied { row["local_variant_read"] = local }
        else { row.removeValue(forKey: "local_variant_read") }
        row["host_review"] = ["run_id": task.id, "read_sha256": receipt.sha256,
                              "text_fingerprint": receipt.text, "analysis_fingerprint": receipt.analysis,
                              "text_scope": row["read_scope"]!,
                              "supplied_text": try receipt.suppliedText.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) } ?? NSNull()]
        return row
    }

    static func equal(_ left: [String: Any], _ right: [String: Any]) -> Bool {
        NSDictionary(dictionary: left).isEqual(to: right)
    }

    static func patched(data: Data, original: [String: Any], sources: [[String: Any]],
                        updates: [String: [String: Any]], task: SecretaryTask,
                        method: String = "Wimm applied version-checked source decisions and verified library state") throws -> Data {
        guard !updates.isEmpty else { return data }
        let patch = try SecretaryJSONPatch(data)
        let members = try patch.members(0..<data.count)
        guard let sourcesRange = members.first(where: { $0.key == "sources" })?.value else { throw Failure("Missing sources array.") }
        let spans = try patch.elements(sourcesRange)
        guard spans.count == sources.count else { throw Failure("Registry changed while preparing revisions.") }
        var edits: [(Range<Int>, Data)] = []
        var revised: [[String: Any]] = []
        var next = sources
        for (index, source) in sources.enumerated() {
            let id = source["source_id"] as! String
            guard let update = updates[id], !equal(source, update) else { continue }
            next[index] = update
            edits.append((spans[index], try SecretaryJSONPatch.encode(update, indent: patch.indentation(at: spans[index].lowerBound))))
            revised.append(["source_id": id, "previous_status": source["status"] ?? NSNull(),
                            "previous_sha256": source["sha256"] ?? NSNull(), "previous_reason": source["reason"] ?? NSNull(),
                            "status": update["status"] ?? NSNull(), "sha256": update["sha256"] ?? NSNull(),
                            "reason": update["reason"] ?? NSNull(),
                            "previous_removed_from_wimm": source["removed_from_wimm"] ?? NSNull(),
                            "removed_from_wimm": update["removed_from_wimm"] ?? NSNull()])
        }
        guard !revised.isEmpty else { return data }
        var counts: [String: Int] = [:]
        for row in next { counts[row["status"] as! String, default: 0] += 1 }
        let batch: [String: Any] = ["kind": "host_review", "run_id": task.id, "date": day(task.createdAt),
                                    "method": method,
                                    "count": revised.count, "revised_sources": revised, "last_scan_changed": false]
        var top: [String: Any] = ["counts": counts, "source_count": next.count, "updated_on": day(task.createdAt)]
        let batches = original["batches"] as? [Any] ?? []
        if let span = members.first(where: { $0.key == "batches" })?.value {
            guard original["batches"] is [Any] else { throw Failure("Registry batches must be an array.") }
            var close = span.upperBound - 1
            while close > span.lowerBound && [9, 10, 13, 32].contains(patch.bytes[close - 1]) { close -= 1 }
            var array = Data(patch.bytes[span.lowerBound..<close])
            if !batches.isEmpty { array.append(Data(",".utf8)) }
            array.append(Data("\n    ".utf8)); array.append(try SecretaryJSONPatch.encode(batch, indent: 4)); array.append(Data("\n  ]".utf8))
            edits.append((span, array))
        } else { top["batches"] = [batch] }
        var missing: [String] = []
        for key in top.keys.sorted() {
            if let member = members.first(where: { $0.key == key }) {
                edits.append((member.value, try SecretaryJSONPatch.encode(top[key]!, indent: 2)))
            } else {
                let encodedKey = try SecretaryJSONPatch.encode(key)
                let encodedValue = try SecretaryJSONPatch.encode(top[key]!, indent: 2)
                missing.append(String(decoding: encodedKey, as: UTF8.self) + ": " + String(decoding: encodedValue, as: UTF8.self))
            }
        }
        if !missing.isEmpty {
            let close = patch.bytes.lastIndex(of: 125)!
            edits.append((close..<close, Data((",\n  " + missing.joined(separator: ",\n  ") + "\n").utf8)))
        }
        return try patch.applying(edits)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
