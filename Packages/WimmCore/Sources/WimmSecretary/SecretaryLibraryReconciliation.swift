import Foundation
import WimmDomain
import WimmInfrastructure

/// Records only a deletion proven by Wimm's own Trash (the note's sidecar is there,
/// nothing of it is left in Recordings). A missing file alone is insufficient. Never restores, deletes, edits a note, or changes semantic status.
enum SecretaryLibraryReconciliation {
    static func removals(sources: [[String: Any]], task: SecretaryTask,
                         active: URL = FileStore.recordingsDirectory(),
                         trash: URL = FileStore.trashDirectory()) -> [String: [String: Any]] {
        var updates: [String: [String: Any]] = [:]
        let manager = FileManager.default
        for source in sources {
            if let flag = source["removed_from_wimm"], !(flag is NSNull), (flag as? Bool) != false { continue }
            guard let id = source["source_id"] as? String,
                  let path = (source["path"] as? String)?.removingPercentEncoding else { continue }
            let url = task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard sameDirectory(url.deletingLastPathComponent(), active.standardizedFileURL.resolvingSymlinksInPath()),
                  !manager.fileExists(atPath: url.path), url.lastPathComponent.hasSuffix(".meta.json") else { continue }
            let stem = String(url.lastPathComponent.dropLast(".meta.json".count))
            if manager.fileExists(atPath: active.appendingPathComponent(stem + ".metadata.json").path) { continue }
            if let file = source["note_file"] as? String, manager.fileExists(atPath: active.appendingPathComponent((file as NSString).lastPathComponent).path) { continue }
            let primary = ["m4a", "caf", "wav", "mp3", "txt", "md", "pdf", "heic", "png", "jpg", "jpeg"]
            if primary.contains(where: { manager.fileExists(atPath: active.appendingPathComponent(stem + "." + $0).path) }) { continue }
            // The sidecar sitting in this library's Trash is the proof. Delete paths differ in
            // whether they also write `trashed`/`trashedAt` (sync and manual moves did not),
            // so that flag is only used for the date when present.
            guard let data = try? Data(contentsOf: trash.appendingPathComponent(url.lastPathComponent)),
                  let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let identity = (metadata["recordingId"] ?? metadata["syncId"]) as? String, !identity.isEmpty else { continue }
            if let expected = source["recording_id"] as? String, expected != identity { continue }
            var updated = source
            updated["removed_from_wimm"] = ["date": SecretaryRegistryRevision.day(task.createdAt),
                                            "reason": "Confirmed deleted in Wimm Trash", "recording_id": identity,
                                            "trashed_at": metadata["trashedAt"] ?? NSNull()]
            updates[id] = updated
        }
        return updates
    }
    /// Repair only a source already owned by one pending mark on a current journal anchor.
    /// This changes a file pointer, never semantic status or reading evidence.
    static func mediaAliases(sources: [[String: Any]], task: SecretaryTask,
                             marks: [String: AgentMarkStore.Mark], indexedFiles: [URL]) -> [String: [String: Any]] {
        let owned = task.workspace.root.appendingPathComponent("recordings").resolvingSymlinksInPath()
        let indexed = Dictionary(indexedFiles.map { ($0.lastPathComponent, $0.resolvingSymlinksInPath()) }, uniquingKeysWith: { a, _ in a })
        let grouped = Dictionary(grouping: marks.filter { $0.value.source != nil }, by: { $0.value.source! })
        var updates: [String: [String: Any]] = [:]
        for row in sources {
            guard let id = row["source_id"] as? String, row["status"] as? String == "pending",
                  !SecretaryBookkeeping.flag(row["primary_text_read"]),
                  !SecretaryBookkeeping.flag(row["removed_from_wimm"]), !SecretaryBookkeeping.flag(row["wimm_unindexed"]),
                  let owners = grouped[id], owners.count == 1, let owner = owners.first, owner.value.status == .pending,
                  let file = indexed[owner.key], (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  sameDirectory(file.deletingLastPathComponent(), owned), !FileStore.isDerivedAudioFile(file),
                  let path = (row["path"] as? String)?.removingPercentEncoding else { continue }
            if let hold = row["user_exclusion"] as? [String: Any], SecretaryBookkeeping.flag(hold["active"]) { continue }
            if let current = row["note_file"] as? String, indexed[current] != nil { continue }
            guard !sources.contains(where: { $0["source_id"] as? String != id && $0["note_file"] as? String == file.lastPathComponent }) else { continue }
            let sidecar = task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard sameDirectory(sidecar.deletingLastPathComponent(), owned), FileManager.default.fileExists(atPath: sidecar.path),
                  FileStore.metadataURL(forRecordingURL: file).resolvingSymlinksInPath() == sidecar else { continue }
            var updated = row
            var history = row["media_file_history"] as? [[String: Any]] ?? []
            history.append(["run_id": task.id, "date": SecretaryRegistryRevision.day(task.createdAt),
                            "previous_file": row["note_file"] ?? NSNull(), "file": file.lastPathComponent,
                            "reason": "Unique existing pending source mark and identical sidecar bind this source to the current journal anchor; no reading or status change."])
            updated["media_file_history"] = history; updated["note_file"] = file.lastPathComponent
            updates[id] = updated
        }
        return updates
    }

    /// A source flagged removed/unindexed (2026-10-25 audit) whose sidecar now belongs to exactly one
    /// visible journal note: restored notes, lost-media notes turned into `.txt`, attachments that became
    /// their own note. User decision 2026-11-14: rebind the source to that note and lift the flag, keeping
    /// the old flag and file in `visibility_history`. Never changes status, reading evidence or holds.
    static func visibleAgain(sources: [[String: Any]], task: SecretaryTask, indexedFiles: [URL]) -> [String: [String: Any]] {
        let owned = task.workspace.root.appendingPathComponent("recordings").resolvingSymlinksInPath()
        let claimed = Set(sources.compactMap { row -> String? in
            guard !SecretaryBookkeeping.flag(row["removed_from_wimm"]), !SecretaryBookkeeping.flag(row["wimm_unindexed"]) else { return nil }
            return row["note_file"] as? String
        })
        // Only sources named by `secretary reconcile --relink-source-id` (environment, so the run inherits it).
        let named = Set((ProcessInfo.processInfo.environment["WIMM_SECRETARY_RELINK_SOURCES"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard !named.isEmpty else { return [:] }
        var updates: [String: [String: Any]] = [:]
        for row in sources {
            guard let id = row["source_id"] as? String, named.contains(id),
                  SecretaryBookkeeping.flag(row["removed_from_wimm"]) || SecretaryBookkeeping.flag(row["wimm_unindexed"]),
                  let path = (row["path"] as? String)?.removingPercentEncoding else { continue }
            let sidecar = task.workspace.document.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard sameDirectory(sidecar.deletingLastPathComponent(), owned), FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            if let hold = row["user_exclusion"] as? [String: Any], SecretaryBookkeeping.flag(hold["active"]) { continue }
            let visible = indexedFiles.filter { file in
                (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                    && sameDirectory(file.deletingLastPathComponent(), owned) && !FileStore.isDerivedAudioFile(file)
                    && FileStore.metadataURL(forRecordingURL: file).resolvingSymlinksInPath() == sidecar
            }
            guard visible.count == 1, let file = visible.first, !claimed.contains(file.lastPathComponent) else { continue }
            var updated = row
            var history = row["visibility_history"] as? [[String: Any]] ?? []
            history.append(["run_id": task.id, "date": SecretaryRegistryRevision.day(task.createdAt),
                            "previous_file": row["note_file"] ?? NSNull(),
                            "removed_from_wimm": row["removed_from_wimm"] ?? NSNull(),
                            "wimm_unindexed": row["wimm_unindexed"] ?? NSNull(), "file": file.lastPathComponent,
                            "reason": "Sidecar belongs to exactly one visible journal note again; source rebound and flag lifted (user decision 2026-11-14). No status or reading change."])
            updated["visibility_history"] = history
            updated["note_file"] = file.lastPathComponent
            updated.removeValue(forKey: "removed_from_wimm"); updated.removeValue(forKey: "wimm_unindexed")
            updates[id] = updated
        }
        return updates
    }

    static func sameDirectory(_ left: URL, _ right: URL) -> Bool {
        // Resolving a missing leaf does not resolve its existing symlink parent
        // on macOS. Resolve the directory itself before comparing its identity.
        let left = left.resolvingSymlinksInPath(), right = right.resolvingSymlinksInPath()
        if left == right { return true }
        // On a case-insensitive volume, the historical _ME symlink may spell
        // "recordings" while StoragePaths spells "Recordings". Compare identity,
        // never lower-case note filenames or accept another library by prefix.
        guard let a = try? FileManager.default.attributesOfItem(atPath: left.path),
              let b = try? FileManager.default.attributesOfItem(atPath: right.path),
              let aFile = a[.systemFileNumber] as? NSNumber, let bFile = b[.systemFileNumber] as? NSNumber,
              let aDevice = a[.systemNumber] as? NSNumber, let bDevice = b[.systemNumber] as? NSNumber else { return false }
        return aFile == bFile && aDevice == bDevice
    }

}
