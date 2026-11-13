import Foundation
import WimmDomain
import WimmInfrastructure

/// An explicit user hold on exact sources (`user_exclusion`), set by Wimm so
/// no agent script edits the registry. Preparation reports a held source in
/// `held_sources` and never reads or acknowledges it (`SecretaryPacket`).
///
/// Only existing registry rows are held: the row whose `path` is the note's
/// sidecar. Its `note_file` becomes the named file (with `media_file_history`),
/// because a hold matches by the exact media file. Status, reading evidence
/// and other flags (`wimm_unindexed`) are not touched; releasing the hold is a
/// separate, explicit user decision. Dry run unless `apply`.
public enum SecretaryUserHold {
    public struct Report: Codable, Sendable {
        public var runID: String
        public var applied: Bool
        /// source id → held file
        public var held: [String: String] = [:]
        public var alreadyHeld: [String] = []
        public var notInRegistry: [String] = []
        public var ambiguous: [String] = []
        public var registryBackup: String?
    }

    public static func hold(document: URL, files: [String], reason: String, apply: Bool, now: Date = Date()) throws -> Report {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw Failure("A hold needs a reason.") }
        let id = SecretaryClock.runID(now) + "-hold"
        let lock = apply ? try SecretaryRunLock.acquire(in: workspace.runsDirectory, runID: id) : nil
        defer { lock?.release() }

        let registryURL = workspace.document.deletingPathExtension().appendingPathExtension("sources.json")
        let data = try Data(contentsOf: registryURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = root["sources"] as? [[String: Any]] else { throw Failure("Invalid registry.") }
        var rowsBySidecar: [String: [[String: Any]]] = [:]
        for row in sources {
            guard let path = (row["path"] as? String)?.removingPercentEncoding,
                  path.hasPrefix("../recordings/"), path.hasSuffix(".meta.json") else { continue }
            rowsBySidecar[String(path.dropFirst("../recordings/".count).dropLast(".meta.json".count)), default: []].append(row)
        }

        let task = SecretaryTask(id: id, kind: .pass, workspace: workspace, threads: [], wimmCLI: "", createdAt: now)
        var report = Report(runID: id, applied: apply)
        var updates: [String: [String: Any]] = [:]
        for file in files {
            let name = (file as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            guard name == file, !stem.isEmpty, !stem.contains("_Attach_") else { report.ambiguous.append(file); continue }
            let rows = rowsBySidecar[stem] ?? []
            guard !rows.isEmpty else { report.notInRegistry.append(name); continue }
            guard rows.count == 1, let row = rows.first, let source = row["source_id"] as? String,
                  updates[source] == nil else { report.ambiguous.append(name); continue }
            if let hold = row["user_exclusion"] as? [String: Any], SecretaryBookkeeping.flag(hold["active"]) {
                report.alreadyHeld.append(source); continue
            }
            var updated = row
            updated["user_exclusion"] = [
                "active": true, "authority": "user", "scope": "source", "resume": "explicit_user_release",
                "reason": reason, "created_at": SecretaryClock.stamp(now),
                "audit": workspace.relative(workspace.runDirectory(id).appendingPathComponent("registry-before-hold.json")),
            ] as [String: Any]
            if row["note_file"] as? String != name {
                var history = row["media_file_history"] as? [[String: Any]] ?? []
                history.append(["run_id": id, "date": SecretaryRegistryRevision.day(now),
                                "previous_file": row["note_file"] ?? NSNull(), "file": name,
                                "reason": "User hold names this file; the hold matches the exact media file. No reading or status change."])
                updated["media_file_history"] = history
                updated["note_file"] = name
            }
            updates[source] = updated
            report.held[source] = name
        }

        guard apply, !updates.isEmpty else { return report }
        let next = try SecretaryRegistryRevision.patched(data: data, original: root, sources: sources, updates: updates, task: task,
                                                         method: "Wimm set explicit user holds (user_exclusion); no reading or status change")
        let directory = workspace.runDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("registry-before-hold.json")
        let audit: [String: Any] = ["run_id": id, "registry_sha256": SecretaryBookkeeping.digest(data),
                                    "sources": sources.filter { updates[$0["source_id"] as! String] != nil }]
        try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: backup, options: .atomic)
        try SecretaryRegistryRevision.snapshot(data, directory: directory)
        guard try Data(contentsOf: registryURL) == data else { throw Failure("Registry changed while setting holds; nothing applied.") }
        try next.write(to: registryURL, options: .atomic)
        report.registryBackup = workspace.relative(backup)
        return report
    }

    /// The files a hold run held, as the registry names them now (`note_file`).
    public static func heldFiles(document: URL, runID: String) throws -> [String] {
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        let ids = Set(try backupRows(workspace: workspace, runID: runID).keys)
        let data = try Data(contentsOf: workspace.document.deletingPathExtension().appendingPathExtension("sources.json"))
        let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["sources"] as? [[String: Any]] ?? []
        return rows.filter { ids.contains($0["source_id"] as? String ?? "") }.compactMap { $0["note_file"] as? String }.sorted()
    }

    /// Undoes a hold run for the named files: each row goes back to its copy in
    /// that run's `registry-before-hold.json`, but only while the row is exactly
    /// what the run left (the backup plus `user_exclusion`, `note_file` and the
    /// one `media_file_history` entry); a row changed since is reported, not touched.
    public static func undo(document: URL, runID: String, files: [String], apply: Bool, now: Date = Date()) throws -> Report {
        guard !PrivateMode.isEnabled else { throw SecretaryError.privateMode }
        guard let workspace = SecretaryWorkspace(document: document) else { throw SecretaryError.notAWorkspace(document.path) }
        let id = SecretaryClock.runID(now) + "-unhold"
        let lock = apply ? try SecretaryRunLock.acquire(in: workspace.runsDirectory, runID: id) : nil
        defer { lock?.release() }
        let originals = try backupRows(workspace: workspace, runID: runID)
        let registryURL = workspace.document.deletingPathExtension().appendingPathExtension("sources.json")
        let data = try Data(contentsOf: registryURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = root["sources"] as? [[String: Any]] else { throw Failure("Invalid registry.") }
        var report = Report(runID: id, applied: apply)
        var updates: [String: [String: Any]] = [:]
        for name in files {
            let matches = sources.filter { $0["note_file"] as? String == name && originals[$0["source_id"] as? String ?? ""] != nil }
            guard matches.count == 1, let row = matches.first, let source = row["source_id"] as? String,
                  let original = originals[source] else { report.notInRegistry.append(name); continue }
            var expected = original
            if let hold = row["user_exclusion"] as? [String: Any] { expected["user_exclusion"] = hold }
            if original["note_file"] as? String != name {
                expected["note_file"] = name
                var history = original["media_file_history"] as? [[String: Any]] ?? []
                if let last = (row["media_file_history"] as? [[String: Any]])?.last, last["run_id"] as? String == runID { history.append(last) }
                expected["media_file_history"] = history
            }
            guard (row["user_exclusion"] as? [String: Any])?["audit"] as? String == workspace.relative(
                    workspace.runDirectory(runID).appendingPathComponent("registry-before-hold.json")),
                  SecretaryRegistryRevision.equal(row, expected) else { report.ambiguous.append(name); continue }
            updates[source] = original
            report.held[source] = name
        }
        guard apply, !updates.isEmpty else { return report }
        let task = SecretaryTask(id: id, kind: .pass, workspace: workspace, threads: [], wimmCLI: "", createdAt: now)
        let next = try SecretaryRegistryRevision.patched(data: data, original: root, sources: sources, updates: updates, task: task,
                                                         method: "Wimm undid user holds of run \(runID) for named sources; rows restored from its backup")
        let directory = workspace.runDirectory(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backup = directory.appendingPathComponent("registry-before-unhold.json")
        let audit: [String: Any] = ["run_id": id, "undoes": runID, "registry_sha256": SecretaryBookkeeping.digest(data),
                                    "sources": sources.filter { updates[$0["source_id"] as! String] != nil }]
        try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: backup, options: .atomic)
        try SecretaryRegistryRevision.snapshot(data, directory: directory)
        guard try Data(contentsOf: registryURL) == data else { throw Failure("Registry changed while undoing holds; nothing applied.") }
        try next.write(to: registryURL, options: .atomic)
        report.registryBackup = workspace.relative(backup)
        return report
    }

    private static func backupRows(workspace: SecretaryWorkspace, runID: String) throws -> [String: [String: Any]] {
        guard runID.hasSuffix("-hold"), !runID.contains("/") else { throw Failure("Not a hold run: \(runID)") }
        let url = workspace.runDirectory(runID).appendingPathComponent("registry-before-hold.json")
        guard let audit = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let rows = audit["sources"] as? [[String: Any]] else { throw Failure("No hold backup in \(runID).") }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in (row["source_id"] as? String).map { ($0, row) } })
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
