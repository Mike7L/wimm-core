import Foundation
import WimmDomain

/// Where the note behind an agent mark is now. Marks are keyed by file name and
/// no delete path touches them, so a mark outlives its note; this tells a note
/// in Wimm's Trash (restorable, deletion proven) from one that is simply gone.
public enum MarkedNotePresence: String, Codable, Sendable, Equatable {
    /// The file is in Recordings.
    case library
    /// Not in Recordings; its file (or a sidecar whose trash marker names it as
    /// `originalPath`) is in Wimm's Trash.
    case trash
    /// Neither: Trash emptied, deleted outside Wimm, or renamed. No proof of a deletion.
    case missing

    /// Looks every file up at once (one Trash scan).
    public static func locate(_ files: some Sequence<String>,
                              active: URL = FileStore.recordingsDirectory(),
                              trash: URL = FileStore.trashDirectory()) -> [String: MarkedNotePresence] {
        let manager = FileManager.default
        var result: [String: MarkedNotePresence] = [:]
        var absent: [String] = []
        for file in files where result[file] == nil {
            if manager.fileExists(atPath: active.appendingPathComponent(file).path) { result[file] = .library }
            else { absent.append(file); result[file] = .missing }
        }
        guard !absent.isEmpty else { return result }
        // Trash may move a group under a free base name; the marker keeps the original path.
        var trashed = Set<String>()
        let names = (try? manager.contentsOfDirectory(atPath: trash.path)) ?? []
        for name in names {
            trashed.insert(name)
            guard name.hasSuffix(".meta.json"),
                  let data = try? Data(contentsOf: trash.appendingPathComponent(name)),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let original = meta["originalPath"] as? String else { continue }
            trashed.insert((original as NSString).lastPathComponent)
        }
        for file in absent where trashed.contains(file) { result[file] = .trash }
        return result
    }
}
