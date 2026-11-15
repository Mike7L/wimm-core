import Foundation

/// The workspace source registry (`<document>.sources.json`), parsed and checked once.
///
/// The registry lives in the workspace, which the outside agent may edit, so a malformed
/// row or a duplicate `source_id` is a thrown `Failure("registry: …")` naming the row,
/// never a crash of the host. Rows stay dictionaries: unknown fields survive untouched
/// and are written back exactly as they were.
struct SecretaryRegistry {
    static let statuses = ["applied", "duplicate", "noise", "pending", "failed"]

    let root: [String: Any]
    /// Every row has a unique `S<n>` `source_id`, a known `status` and a string `path`.
    let rows: [[String: Any]]
    let byID: [String: [String: Any]]
    let counts: [String: Int]
    /// Highest `S<n>` number in use (0 for an empty registry).
    let maxNumber: Int

    static func url(document: URL) -> URL {
        document.deletingPathExtension().appendingPathExtension("sources.json")
    }

    static func parse(_ data: Data) throws -> SecretaryRegistry {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw Failure("registry: not valid JSON (\(error.localizedDescription))") }
        guard let root = object as? [String: Any] else { throw Failure("registry: top level is not an object") }
        guard let value = root["sources"] else { throw Failure("registry: no sources array") }
        guard let list = value as? [Any] else { throw Failure("registry: sources is not an array") }
        var rows: [[String: Any]] = [], byID: [String: [String: Any]] = [:], counts: [String: Int] = [:], maximum = 0
        rows.reserveCapacity(list.count)
        for (index, element) in list.enumerated() {
            let at = "registry: sources[\(index)]"
            guard let row = element as? [String: Any] else { throw Failure("\(at) is not an object") }
            guard let rawID = row["source_id"] else { throw Failure("\(at): missing source_id") }
            guard let id = rawID as? String else { throw Failure("\(at): source_id is not a string") }
            guard let number = number(id) else { throw Failure("\(at): source_id \(quoted(id)) is not S<number>") }
            guard byID[id] == nil else { throw Failure("\(at): duplicate source_id \(id)") }
            guard let rawStatus = row["status"] else { throw Failure("\(at) (\(id)): missing status") }
            guard let status = rawStatus as? String else { throw Failure("\(at) (\(id)): status is not a string") }
            guard statuses.contains(status) else {
                throw Failure("\(at) (\(id)): unknown status \(quoted(status)); expected one of \(statuses.joined(separator: ", "))")
            }
            guard let path = row["path"] else { throw Failure("\(at) (\(id)): missing path") }
            guard path is String else { throw Failure("\(at) (\(id)): path is not a string") }
            rows.append(row); byID[id] = row
            counts[status, default: 0] += 1
            maximum = max(maximum, number)
        }
        return SecretaryRegistry(root: root, rows: rows, byID: byID, counts: counts, maxNumber: maximum)
    }

    /// `source_count` and `counts` must agree with the rows.
    func checkCounts() throws {
        guard root["source_count"] as? Int == rows.count, root["counts"] as? [String: Int] == counts else {
            throw Failure("Registry source_count/counts disagree with sources.")
        }
    }

    /// Registry rows plus rows this pass is adding, by id; a clash is an error, not a crash.
    func indexed(adding added: [[String: Any]]) throws -> [String: [String: Any]] {
        try Self.index(rows + added)
    }

    /// Rows by `source_id`. Throws on a row without a string id or on a duplicate id.
    static func index(_ rows: [[String: Any]]) throws -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        result.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard let id = row["source_id"] as? String else { throw Failure("registry: sources[\(index)]: missing source_id") }
            guard result.updateValue(row, forKey: id) == nil else { throw Failure("registry: sources[\(index)]: duplicate source_id \(id)") }
        }
        return result
    }

    /// `S<n>` → n, within `Int` and below `Int.max` so the next id still fits.
    static func number(_ id: String) -> Int? {
        // `^S[0-9]+$` byte by byte: a regular expression per row was measurable on ~8k rows.
        // (`$` also matched before a final newline, which `Int` then rejected anyway.)
        let digits = id.utf8.dropFirst()
        guard id.utf8.first == UInt8(ascii: "S"), !digits.isEmpty,
              digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let number = Int(id.dropFirst()), number < Int.max else { return nil }
        return number
    }

    private static func quoted(_ text: String) -> String { "\"\(text.prefix(80))\"" }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
