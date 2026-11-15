import Foundation
import WimmDomain

/// A user-approved list of notes moved to `Trash/` in one go (`wimm-cli notes trash`).
///
/// Only names the user listed are touched, each must be an existing note file directly
/// in `Recordings/` (no paths, no sidecars, no derived audio), and every move goes
/// through `RecordingTrashSupport.moveToTrash`, so nothing is deleted and each note can
/// be restored. iCloud tombstones are a separate step (`wimm-cli sync tombstone-trash`).
public enum NoteTrashBatch {
    public enum Rejection: String, CaseIterable, Sendable {
        case notAName = "not a plain file name"
        case notFound = "not found in Recordings"
        case notANote = "sidecar or derived file, not a note"
        case duplicate = "listed twice"
    }

    public struct Plan: Sendable {
        public var notes: [URL] = []
        public var rejected: [(name: String, reason: Rejection)] = []
    }

    public static func plan(names: [String], fileManager: FileManager = .default) -> Plan {
        let recordings = FileStore.recordingsDirectory()
        var plan = Plan()
        var seen = Set<String>()
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            guard !name.contains("/"), name != ".", name != ".." else {
                plan.rejected.append((name, .notAName)); continue
            }
            guard seen.insert(name).inserted else {
                plan.rejected.append((name, .duplicate)); continue
            }
            let url = recordings.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                plan.rejected.append((name, .notFound)); continue
            }
            guard !name.hasSuffix(".meta.json"), !FileStore.isDerivedAudioFile(url) else {
                plan.rejected.append((name, .notANote)); continue
            }
            plan.notes.append(url)
        }
        return plan
    }

    /// Moves every planned note; returns the trashed URLs and the names that failed.
    public static func apply(_ plan: Plan) -> (trashed: [URL], failed: [String]) {
        var trashed: [URL] = []
        var failed: [String] = []
        for url in plan.notes {
            if let moved = RecordingTrashSupport.moveToTrash(file: url, onFailure: { source, error in
                log("[NotesTrash] could not move \(source.lastPathComponent): \(error)")
            }) {
                trashed.append(moved)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        return (trashed, failed)
    }
}
