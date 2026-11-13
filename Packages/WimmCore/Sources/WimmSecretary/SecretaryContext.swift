import Foundation
import WimmDomain
import WimmInfrastructure

/// A bounded projection of the existing registry/document, rebuilt on demand.
/// No second index or semantic decisions; unknown registry fields stay on disk.
public enum SecretaryContext {
    public static func registry(document: URL, references: [String] = [], query: String? = nil,
                                limit: Int = 20, offset: Int = 0) throws -> Data {
        let url = document.deletingPathExtension().appendingPathExtension("sources.json")
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let sources = object["sources"] as? [[String: Any]] else { throw Failure("Registry has no sources array.") }
        var ids = Set<String>(), maximum = 0
        var counts: [String: Int] = [:]
        for source in sources {
            guard let id = source["source_id"] as? String,
                  id.range(of: #"^S[0-9]+$"#, options: .regularExpression) != nil,
                  let number = Int(id.dropFirst()), number < Int.max, ids.insert(id).inserted,
                  let status = source["status"] as? String,
                  ["applied", "duplicate", "noise", "pending", "failed"].contains(status), source["path"] is String else {
                throw Failure("Invalid/duplicate source in registry.")
            }
            maximum = max(maximum, number)
            counts[status, default: 0] += 1
        }
        guard object["source_count"] as? Int == sources.count, object["counts"] as? [String: Int] == counts else {
            throw Failure("Registry source_count/counts disagree with sources.")
        }
        let terms = (query ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let selecting = !references.isEmpty || !terms.isEmpty
        let matches = selecting ? sources.filter { source in
            let referenceMatches = references.isEmpty || references.contains { reference in
                if reference == source["source_id"] as? String { return true }
                let rawPath = (source["path"] as? String ?? "").removingPercentEncoding ?? ""
                let file = (rawPath as NSString).lastPathComponent
                let refName = (reference as NSString).lastPathComponent
                // Exact spelling, including leading spaces. No prefix or fuzzy resolution.
                return reference == source["path"] as? String || refName == file
                    || refName == source["note_file"] as? String
                    || FileStore.metadataURL(forRecordingURL: URL(fileURLWithPath: refName)).lastPathComponent == file
            }
            let searchable = ["source_id", "path", "note_file", "status", "reason"].compactMap { source[$0] as? String }.joined(separator: "\n").lowercased()
            return referenceMatches && terms.allSatisfy { searchable.contains($0) }
        } : []
        let lower = min(max(0, offset), matches.count)
        let upper = min(matches.count, lower + min(20, max(1, limit)))
        let fields = ["source_id", "path", "note_file", "status", "reason", "sha256", "read_sha256", "read_scope",
                      "primary_text_read", "audio_listened", "original_image_viewed", "reviewed_on", "duplicate_of", "merged_with",
                      "removed_from_wimm", "wimm_unindexed"]
        let selected: [[String: Any]] = matches[lower..<upper].map { source in
            var row: [String: Any] = [:]
            var truncated: [String] = []
            for key in fields {
                guard let value = source[key] else { continue }
                if let string = value as? String, string.count > 1200 {
                    row[key] = String(string.prefix(1200)); truncated.append(key)
                } else if let array = value as? [Any], array.count > 20 {
                    row[key] = Array(array.prefix(20)); truncated.append(key)
                } else { row[key] = value }
            }
            if !truncated.isEmpty { row["truncated_fields"] = truncated }
            return row
        }
        var out: [String: Any] = ["registry": url.lastPathComponent, "source_count": sources.count, "counts": counts,
                                  "next_source_id": "S\(maximum + 1)", "selection_requested": selecting,
                                  "matched": matches.count, "offset": lower, "sources": selected,
                                  "projection": "Selected fields only. Preserve unshown fields when editing; do not replace a full registry row with this projection."]
        if upper < matches.count { out["next_offset"] = upper }
        if let period = object["period_end"] as? String {
            out["period_end"] = String(period.prefix(200))
            if period.count > 200 { out["period_end_truncated"] = true }
        }
        return try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Generated once per managed run. Headings carry line numbers, never hidden body excerpts.
    static func write(task: SecretaryTask, directory: URL) throws {
        var context: [String: Any] = ["document": task.workspace.doc]
        if task.kind == .pass {
            let summary = try registry(document: task.workspace.document)
            context["registry"] = try JSONSerialization.jsonObject(with: summary)
            let registry = task.workspace.document.deletingPathExtension().appendingPathExtension("sources.json")
            try SecretaryRegistryRevision.snapshot(Data(contentsOf: registry), directory: directory)
        }
        let text = try String(contentsOf: task.workspace.document, encoding: .utf8)
        var headings: [String] = [], total = 0
        var fence: String?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            guard fence == nil else { continue }
            let level = line.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level), line.dropFirst(level).hasPrefix(" ") else { continue }
            total += 1
            if headings.count < 200 {
                headings.append("\(index + 1) \(String(line.prefix(200)))")
            }
        }
        let outlineName = "document-outline.txt"
        let outline = "headings: total=\(total), shown=\(headings.count), truncated=\(total > headings.count)\n" + headings.joined(separator: "\n") + "\n"
        try Data(outline.utf8).write(to: directory.appendingPathComponent(outlineName), options: .atomic)
        context["document_outline"] = "\(task.runDirectory)/\(outlineName)"
        let data = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys, .withoutEscapingSlashes])
        try data.write(to: directory.appendingPathComponent("context.json"), options: .atomic)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
