import CryptoKit
import Foundation
import WimmDomain

/// A note split off a parent by `AttachmentSplitMigration` carries text the secretary
/// already read as part of that parent (its sidecar `attachments` text was in the packets).
/// Without a mark of its own it would come back as new and fill whole packets
/// (2026-11-21: 4528 Evernote attachments, ~15 MB). This gives such a note its
/// parent's settled mark (`applied` / `noise`, same `source`) when nothing in its
/// text is newer than that mark. Everything else stays unmarked and goes to the
/// secretary: a parent never marked, marked `pending`/`failed`, or a child whose
/// transcript or edit came after the parent's mark. An existing child mark is
/// never replaced. Dry-run unless `apply`; marks only, notes are never written.
public enum SplitMarkInheritance {
    public static let tool = "inherit-split-marks"

    public enum Action: String, Codable, Sendable, CaseIterable {
        /// Gets the parent's mark.
        case inherit
        /// Already has a mark of its own.
        case alreadyMarked = "already-marked"
        /// The parent has no mark: the secretary never settled it.
        case parentUnmarked = "parent-unmarked"
        /// The parent is `pending` or `failed`: nothing settled to inherit.
        case parentUnsettled = "parent-unsettled"
        /// The child's transcript or edit is newer than the parent's mark.
        case changedSinceParentMark = "changed-since-parent-mark"
        /// The `splitFrom` file is not in `Recordings/`.
        case missingFile = "missing-file"
    }

    public struct Item: Codable, Sendable, Equatable {
        public var file: String
        public var parent: String?
        public var action: Action
        public var status: String?
        public var source: String?
    }

    public struct Report: Codable, Sendable {
        public var tool = SplitMarkInheritance.tool
        public var dryRun: Bool
        public var library: String
        public var at: String
        public var byAction: [String: Int] = [:]
        /// Of `inherit`: the inherited status.
        public var inheritedStatus: [String: Int] = [:]
        public var items: [Item] = []
    }

    /// - Parameter only: child note file names to consider (the migration passes the ones it just wrote).
    public static func run(library: URL = StoragePaths.baseDirectory(), marks: AgentMarkStore? = nil,
                           apply: Bool, only: Set<String>? = nil, now: Date = Date()) throws -> Report {
        let marks = marks ?? AgentMarkStore(directory: library.appendingPathComponent("AgentState", isDirectory: true))
        let recordings = library.appendingPathComponent("Recordings", isDirectory: true)
        let known = marks.marks()
        // Marks are keyed by the note file; a parent sidecar names only the base.
        var parentMarks: [String: (file: String, mark: AgentMarkStore.Mark)] = [:]
        for (file, mark) in known.sorted(by: { $0.key < $1.key }) {
            let base = (file as NSString).deletingPathExtension
            if parentMarks[base] == nil { parentMarks[base] = (file, mark) }
        }
        var report = Report(dryRun: !apply, library: library.path, at: ISO8601.string(from: now))
        var changes: [String: AgentMarkStore.Mark?] = [:]
        let names = try FileManager.default.contentsOfDirectory(atPath: recordings.path).sorted()
        for name in names where name.hasSuffix(".meta.json") {
            let sidecarURL = recordings.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: sidecarURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let split = json[AttachmentSplitMigration.splitFromKey] as? [String: Any],
                  let file = split["file"] as? String else { continue }
            if let only, !only.contains(file) { continue }
            let parentBase = (split["parentSidecar"] as? String).map { String($0.dropLast(".meta.json".count)) }
            let parent = parentBase.flatMap { parentMarks[$0] }
            var item = Item(file: file, parent: parent?.file, action: .inherit)
            let url = recordings.appendingPathComponent(file)
            if known[file] != nil {
                item.action = .alreadyMarked
            } else if !FileManager.default.fileExists(atPath: url.path) {
                item.action = .missingFile
            } else if let parent {
                item.status = parent.mark.status.rawValue
                item.source = parent.mark.source
                if parent.mark.status != .applied && parent.mark.status != .noise {
                    item.action = .parentUnsettled
                } else if !NoteChangeKind.kinds(forRecordingURL: url, since: parent.mark.markedAt)
                            .filter({ $0 == .transcript || $0 == .edited }).isEmpty {
                    item.action = .changedSinceParentMark
                } else {
                    let fingerprint = NoteFingerprint.read(forRecordingURL: url)
                    let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    changes[file] = AgentMarkStore.Mark(
                        status: parent.mark.status, source: parent.mark.source,
                        comment: "inherited from \(parent.file) (\(AttachmentSplitMigration.tool))",
                        markedAt: now, noteId: json["recordingId"] as? String ?? (file as NSString).deletingPathExtension,
                        sidecarSHA256: sha, text: fingerprint.text, analysis: fingerprint.analysis,
                        wording: fingerprint.wording)
                    report.inheritedStatus[parent.mark.status.rawValue, default: 0] += 1
                }
            } else {
                item.action = .parentUnmarked
            }
            report.byAction[item.action.rawValue, default: 0] += 1
            report.items.append(item)
        }
        if apply, !changes.isEmpty { try marks.update(changes) }
        return report
    }
}
