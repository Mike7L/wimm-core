import Foundation
import WimmDomain

/// Copies Apple Voice Memos into the library from a reviewed plan file
/// (`wimm-cli notes import-voicememos`). The plan decides what is imported
/// (audio-duplicate and empty-file checks happen outside, with the real
/// record dates from `CloudRecordings.db`); this code only does the safe
/// writing: no re-encode, no overwrite, no transcription, no `attachments`,
/// sidecar through `FileStore.upsertMetadata`. It does not touch the sync
/// ledger: a new note without `syncId` is picked up by the next app sync.
public enum VoiceMemosImport {
    public struct Plan: Codable, Sendable {
        public var sourceDir: String
        public var items: [Item]
    }

    public struct Item: Codable, Sendable {
        public var src: String
        public var dst: String
        /// ISO-8601 UTC record date.
        public var timestamp: String
        public var dateSource: String?
        public var size: Int?
        public var label: String?
        public var borderline: String?
    }

    public enum Outcome: Sendable, Equatable {
        case wouldImport
        case imported
        case skipped(String)
        case failed(String)
    }

    public struct Row: Sendable {
        public let item: Item
        public let outcome: Outcome
    }

    public static func load(planAt url: URL) throws -> Plan {
        try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
    }

    /// Imports (or, with `apply == false`, only checks) the plan's items in
    /// order, at most `limit` of them that are actually importable.
    public static func run(
        plan: Plan,
        destination: URL = FileStore.recordingsDirectory(),
        apply: Bool,
        limit: Int? = nil,
        now: Date = Date()
    ) -> [Row] {
        let fm = FileManager.default
        let sourceDir = URL(fileURLWithPath: plan.sourceDir, isDirectory: true)
        let importedAt = ISO8601DateFormatter().string(from: now)
        var rows: [Row] = []
        var done = 0
        var seen = Set<String>()

        for item in plan.items {
            if let limit, done >= limit { break }
            func row(_ outcome: Outcome) { rows.append(Row(item: item, outcome: outcome)) }

            guard item.dst == (item.dst as NSString).lastPathComponent,
                  item.src == (item.src as NSString).lastPathComponent,
                  item.dst.hasPrefix("Wimm_"), item.dst.hasSuffix(".m4a") else {
                row(.failed("bad file name")); continue
            }
            guard let date = WimmDomain.ISO8601.parseEither(item.timestamp) else {
                row(.failed("bad timestamp \(item.timestamp)")); continue
            }
            guard date <= now.addingTimeInterval(60) else {
                row(.skipped("date in the future")); continue
            }
            guard seen.insert(item.dst).inserted else {
                row(.skipped("duplicate destination in plan")); continue
            }
            let source = sourceDir.appendingPathComponent(item.src)
            let attrs = try? fm.attributesOfItem(atPath: source.path)
            guard let sourceSize = (attrs?[.size] as? NSNumber)?.intValue else {
                row(.skipped("source missing")); continue
            }
            if let expected = item.size, expected != sourceSize {
                row(.skipped("source size changed (\(expected) → \(sourceSize))")); continue
            }
            let dest = destination.appendingPathComponent(item.dst)
            let sidecar = FileStore.metadataURL(forRecordingURL: dest)
            if fm.fileExists(atPath: dest.path) || fm.fileExists(atPath: sidecar.path) {
                row(.skipped("destination exists")); continue
            }

            done += 1
            guard apply else { row(.wouldImport); continue }

            let part = destination.appendingPathComponent(".voicememos-import-\(item.dst).part")
            do {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                try? fm.removeItem(at: part)
                try fm.copyItem(at: source, to: part)
                try fm.moveItem(at: part, to: dest)
                _ = FileStore.trySetFileDates(dest, created: date, modified: date)

                var voiceMemos: [String: Any] = ["file": item.src]
                if let source = item.dateSource { voiceMemos["dateSource"] = source }
                if let label = item.label, !label.isEmpty { voiceMemos["label"] = label }
                FileStore.upsertMetadata(for: dest, updates: [
                    MetadataKey.sourcePath.rawValue: source.path,
                    "timestamp": item.timestamp,
                    "importedAt": importedAt,
                    // What `RecordingMetadata` needs to decode the sidecar on iPhone.
                    "recordingURL": FileStore.relativePath(for: dest),
                    "isComplete": true,
                    "lastSaved": importedAt,
                    "duration": 0,
                    "voiceMemos": voiceMemos
                ])
                row(.imported)
            } catch {
                try? fm.removeItem(at: part)
                row(.failed(String(describing: error)))
            }
        }
        return rows
    }
}
