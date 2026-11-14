import CryptoKit
import Foundation
import WimmDomain
import WimmInfrastructure

/// `wimm-cli notes merge-voicememos-duplicates`: an imported Voice Memo (real
/// record date in its name) takes over the analysis of the earlier iPhone
/// import of the same recording (wrong date, `Wimm_2026-10-19_…`), then the
/// old note goes to Trash. Dry run unless `apply`.
///
/// Per pair, nothing is written unless every check passes; a pair that fails
/// is skipped whole and reported. Order of writes: sidecar keys → fingerprint
/// check → marks → `_ME` registry and `[S…]:` definitions (one backup) →
/// old note to Trash. Every step is idempotent, so a rerun after a failure
/// continues instead of duplicating. The cloud tombstone for the old note is
/// not sent here (the CLI has no CloudKit): the trash log it writes is fed to
/// `wimm-cli sync tombstone-trash --apply --from-log`.
///
/// Twins: the 19.10 import sometimes holds two copies of one sound (`twins`),
/// each with its own S. The pair's `old` is the copy whose analysis moves;
/// a twin must have the same current transcript and the same registry status.
/// Its S keeps its status and now points at the same imported note
/// (`removed_from_wimm` + `merged_with`, `note_file` stays the twin's own name
/// so no two live rows name one note), its mark is dropped, its transcription
/// and card are kept under `voiceMemos.mergedCopies` (outside the fingerprint),
/// and it goes to Trash with the old note.
public enum VoiceMemosMerge {
    public struct Pair: Codable, Sendable, Equatable {
        public var old: String
        public var new: String
        /// Other 19.10 copies of the same sound, merged into the same import.
        public var twins: [String]?
        /// The user decided (per pair) that a twin may keep a different registry
        /// status: the pair's S stays primary, the twin's status is left as it is.
        public var allowStatusMismatch: Bool?
        /// No import exists: `old` == `new` is a 19.10 copy that stays as it is
        /// (no sidecar write); only its twins are merged into it.
        public var keepInPlace: Bool?
        /// Other Voice Memos imports of the same sound with nothing of their own
        /// (no transcription, no registry row, no mark): trashed and logged.
        public var duplicateImports: [String]?
        public init(old: String, new: String, twins: [String]? = nil, allowStatusMismatch: Bool? = nil,
                    keepInPlace: Bool? = nil, duplicateImports: [String]? = nil) {
            self.old = old; self.new = new; self.twins = twins; self.allowStatusMismatch = allowStatusMismatch
            self.keepInPlace = keepInPlace; self.duplicateImports = duplicateImports
        }
        var inPlace: Bool { keepInPlace == true }
    }

    public struct PairFile: Codable, Sendable {
        public var pairs: [Pair]
        public init(pairs: [Pair]) { self.pairs = pairs }
    }

    public struct Options: Sendable {
        public var recordings: URL
        public var agentState: URL
        /// The secretary workspace root (`_ME`); nil skips its registry (only
        /// allowed in a dry run).
        public var workspace: URL?
        public var backupDirectory: URL
        public var apply: Bool
        public var limit: Int?
        public var now: Date

        public init(recordings: URL = FileStore.recordingsDirectory(),
                    agentState: URL = StoragePaths.baseDirectory().appendingPathComponent("AgentState"),
                    workspace: URL?, backupDirectory: URL, apply: Bool, limit: Int? = nil, now: Date = Date()) {
            self.recordings = recordings; self.agentState = agentState; self.workspace = workspace
            self.backupDirectory = backupDirectory; self.apply = apply; self.limit = limit; self.now = now
        }
    }

    public enum Outcome: Sendable, Equatable {
        case wouldMerge
        case merged
        case alreadyDone
        case skipped(String)
        case failed(String)
    }

    public struct Row: Sendable {
        public let pair: Pair
        public let outcome: Outcome
        public var source: String?
        public var twinSources: [String] = []
    }

    static let transferKeys = ["transcription", "noteCard", "origin"]

    struct Prepared {
        let pair: Pair
        let oldURL: URL
        let newURL: URL
        let transfer: [String: Any]
        let alreadyTransferred: Bool
        let oldBase: String
        let newBase: String
        let sourceID: String?
        var twins: [Twin] = []
        var duplicateImports: [URL] = []
    }

    struct Twin {
        let name: String
        let url: URL
        let base: String
        let sourceID: String?
        /// Kept under `voiceMemos.mergedCopies`; nil once it is there.
        let record: [String: Any]?
        /// False when an earlier run already moved it to Trash.
        let present: Bool
    }

    // MARK: - Run

    public static func load(pairsAt url: URL) throws -> [Pair] {
        try JSONDecoder().decode(PairFile.self, from: Data(contentsOf: url)).pairs
    }

    public static func run(pairs: [Pair], options: Options) -> [Row] {
        var rows: [Row] = []
        var eligible: [Prepared] = []
        var marks = AgentMarkStore(directory: options.agentState).marks()
        let registry = options.workspace.flatMap { loadRegistry($0) }

        for pair in pairs {
            if let limit = options.limit, eligible.count >= limit { break }
            switch prepare(pair, options: options, marks: &marks, registry: registry) {
            case .failure(let why): rows.append(Row(pair: pair, outcome: .skipped(why.description)))
            case .success(let item): eligible.append(item)
            }
        }
        guard options.apply else {
            return rows + eligible.map { Row(pair: $0.pair, outcome: .wouldMerge, source: $0.sourceID, twinSources: $0.twins.compactMap(\.sourceID)) }
        }
        guard let workspace = options.workspace else {
            return rows + eligible.map { Row(pair: $0.pair, outcome: .failed("--workspace is required to apply"), source: $0.sourceID) }
        }

        let fm = FileManager.default
        let stamp = stamp(options.now)
        let backup = options.backupDirectory.appendingPathComponent("voicememos-merge-\(stamp)", isDirectory: true)
        do {
            try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            try backupFile(options.agentState.appendingPathComponent("marks.json"), into: backup)
            for item in eligible {
                for url in [sidecar(item.oldURL), sidecar(item.newURL)] + item.twins.map({ sidecar($0.url) })
                    + item.duplicateImports.map({ sidecar($0) }) {
                    try backupFile(url, into: backup)
                }
            }
        } catch {
            return rows + eligible.map { Row(pair: $0.pair, outcome: .failed("backup failed: \(error)"), source: $0.sourceID) }
        }

        // Phase 2: sidecar + marks, per pair.
        var phase2: [Prepared] = []
        let store = AgentMarkStore(directory: options.agentState)
        for item in eligible {
            do {
                if !item.pair.inPlace { try mergeSidecar(item, now: options.now) }
                try moveMark(item, store: store, marks: marks)
                phase2.append(item)
            } catch {
                rows.append(Row(pair: item.pair, outcome: .failed(String(describing: error)), source: item.sourceID))
            }
        }

        // Phase 3: `_ME` registry and definitions, one coordinated step.
        var done: [Prepared] = []
        do {
            try patchWorkspace(phase2, workspace: workspace, options: options, stamp: stamp)
            done = phase2
        } catch {
            for item in phase2 {
                rows.append(Row(pair: item.pair, outcome: .failed("workspace step failed, old note kept: \(error)"), source: item.sourceID))
            }
        }

        // Phase 4: the old notes to Trash, with a log for the tombstone step.
        // The log is rewritten (atomically) after every move, so an interrupted
        // run still leaves a complete log of what it trashed. A rerun also logs
        // old notes an earlier run already trashed, found in Trash by name and
        // `originalPath`, so its log covers every merged pair.
        let logURL = backup.appendingPathComponent("trash_log.json")
        var log: [[String]] = []
        for item in done {
            var twinFailed = false
            for twin in item.twins {
                if fm.fileExists(atPath: twin.url.path) {
                    guard let trashed = RecordingTrashSupport.moveToTrash(file: twin.url) else { twinFailed = true; continue }
                    log.append([twin.url.path, trashed.path])
                } else if let trashed = trashedCopy(of: twin.url) {
                    log.append([twin.url.path, trashed.path])
                }
            }
            for duplicate in item.duplicateImports {
                if FileManager.default.fileExists(atPath: duplicate.path) {
                    guard let trashed = RecordingTrashSupport.moveToTrash(file: duplicate) else { twinFailed = true; continue }
                    log.append([duplicate.path, trashed.path])
                } else if let trashed = trashedCopy(of: duplicate) {
                    log.append([duplicate.path, trashed.path])
                }
            }
            if twinFailed {
                rows.append(Row(pair: item.pair, outcome: .failed("could not move a twin to Trash; old note kept"), source: item.sourceID))
                if !log.isEmpty { try? writeTrashLog(log, to: logURL) }
                continue
            }
            if item.pair.inPlace {
                rows.append(Row(pair: item.pair, outcome: item.twins.contains(where: \.present) ? .merged : .alreadyDone,
                                source: item.sourceID, twinSources: item.twins.compactMap(\.sourceID)))
            } else if fm.fileExists(atPath: item.oldURL.path) {
                guard let trashed = RecordingTrashSupport.moveToTrash(file: item.oldURL) else {
                    rows.append(Row(pair: item.pair, outcome: .failed("could not move the old note to Trash"), source: item.sourceID))
                    continue
                }
                log.append([item.oldURL.path, trashed.path])
                rows.append(Row(pair: item.pair, outcome: .merged, source: item.sourceID, twinSources: item.twins.compactMap(\.sourceID)))
            } else {
                if let trashed = trashedCopy(of: item.oldURL) { log.append([item.oldURL.path, trashed.path]) }
                rows.append(Row(pair: item.pair, outcome: .alreadyDone, source: item.sourceID, twinSources: item.twins.compactMap(\.sourceID)))
            }
            if !log.isEmpty {
                do { try writeTrashLog(log, to: logURL) } catch {
                    rows.append(Row(pair: item.pair, outcome: .failed("trash log not written: \(error)"), source: item.sourceID))
                }
            }
        }
        return rows
    }

    /// `[[from, to]]`, the format `sync tombstone-trash --from-log` reads.
    static func writeTrashLog(_ log: [[String]], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: log, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }

    /// The old note's copy in Trash, if this merge (or an earlier interrupted
    /// run of it) put it there: same file name, and its trash marker points
    /// back at the old path.
    static func trashedCopy(of oldURL: URL) -> URL? {
        let candidate = FileStore.trashDirectory().appendingPathComponent(oldURL.lastPathComponent)
        guard FileManager.default.fileExists(atPath: candidate.path),
              let meta = readDict(sidecar(candidate)),
              let original = meta["originalPath"] as? String,
              URL(fileURLWithPath: original).standardizedFileURL.path == oldURL.standardizedFileURL.path
        else { return nil }
        return candidate
    }

    // MARK: - Checks (no writes)

    static func prepare(_ pair: Pair, options: Options, marks: inout [String: AgentMarkStore.Mark],
                        registry: [String: Any]?) -> Result<Prepared, SkipReason> {
        func plain(_ name: String) -> Bool {
            name == (name as NSString).lastPathComponent && name.hasPrefix("Wimm_") && name.hasSuffix(".m4a")
        }
        guard plain(pair.old), plain(pair.new), pair.inPlace ? pair.old == pair.new : pair.old != pair.new else {
            return .failure("bad file names")
        }
        if pair.inPlace { return prepareInPlace(pair, options: options, marks: marks, registry: registry) }
        let oldURL = options.recordings.appendingPathComponent(pair.old)
        let newURL = options.recordings.appendingPathComponent(pair.new)
        let fm = FileManager.default
        guard fm.fileExists(atPath: newURL.path), let new = readDict(sidecar(newURL)) else {
            return .failure("imported note or its sidecar is missing")
        }
        guard new["voicememos"] == nil, new["voiceMemos"] != nil else { return .failure("new note is not a Voice Memos import") }
        guard new["attachments"] == nil else { return .failure("new note has attachments") }

        let oldBase = String(pair.old.dropLast(4)), newBase = String(pair.new.dropLast(4))
        let oldExists = fm.fileExists(atPath: oldURL.path)
        var transfer: [String: Any] = [:]
        var already = false

        if oldExists {
            guard let old = readDict(sidecar(oldURL)) else { return .failure("old sidecar unreadable") }
            guard old["attachments"] == nil else { return .failure("old note has attachments") }
            guard let transcription = old["transcription"] as? [String: Any], !transcription.isEmpty else {
                return .failure("old note has no transcription to move")
            }
            for key in transferKeys {
                guard let value = old[key] else { continue }
                if let existing = new[key] {
                    guard NSDictionary(dictionary: ["v": existing]).isEqual(to: ["v": value]) else {
                        return .failure(SkipReason(stringLiteral: "conflict: new note already has a different \(key)"))
                    }
                    already = true
                } else {
                    transfer[key] = value
                }
            }
            var merged = new
            for (key, value) in transfer { merged[key] = value }
            let before = NoteFingerprint.make(sidecar: old)
            let after = NoteFingerprint.make(sidecar: merged)
            guard before.text == after.text, before.analysis == after.analysis, before.wording == after.wording else {
                return .failure("fingerprint would change")
            }
        } else {
            // The old note is already gone: only fine when the transfer happened.
            guard new["transcription"] != nil else { return .failure("old note is missing and nothing was transferred") }
            already = true
        }

        var sourceID: String?
        var primaryStatus: String?
        if let registry {
            // A row whose note left Wimm (`removed_from_wimm`, e.g. a merged twin) names no live source.
            let live = registryRows(registry).filter { !SecretaryBookkeeping.flag($0["removed_from_wimm"]) }
            let oldSources = live.filter { rowMatches($0, base: oldBase) }
            let newSources = live.filter { rowMatches($0, base: newBase) }
            if oldSources.count == 1, newSources.isEmpty { sourceID = oldSources[0]["source_id"] as? String }
            else if oldSources.isEmpty, newSources.count == 1 { sourceID = newSources[0]["source_id"] as? String }
            else if oldSources.isEmpty, newSources.isEmpty { sourceID = nil }
            else { return .failure(SkipReason(stringLiteral: "registry rows ambiguous (\(oldSources.count) old, \(newSources.count) new)")) }
            primaryStatus = (oldSources.first ?? newSources.first)?["status"] as? String
        }
        var twins: [Twin] = []
        for name in pair.twins ?? [] {
            switch prepareTwin(name, pair: pair, options: options, new: new, registry: registry,
                               primarySource: sourceID, primaryStatus: primaryStatus, marks: marks) {
            case .failure(let why): return .failure(why)
            case .success(let twin): twins.append(twin)
            }
        }
        var duplicates: [URL] = []
        for name in pair.duplicateImports ?? [] {
            switch prepareDuplicateImport(name, pair: pair, options: options, marks: marks, registry: registry) {
            case .failure(let why): return .failure(why)
            case .success(let url): if let url { duplicates.append(url) }
            }
        }
        return .success(Prepared(pair: pair, oldURL: oldURL, newURL: newURL, transfer: transfer,
                                 alreadyTransferred: already && transfer.isEmpty,
                                 oldBase: oldBase, newBase: newBase, sourceID: sourceID, twins: twins,
                                 duplicateImports: duplicates))
    }

    static func prepareInPlace(_ pair: Pair, options: Options, marks: [String: AgentMarkStore.Mark],
                               registry: [String: Any]?) -> Result<Prepared, SkipReason> {
        guard !(pair.twins ?? []).isEmpty, (pair.duplicateImports ?? []).isEmpty else { return .failure("keep-in-place needs twins only") }
        let url = options.recordings.appendingPathComponent(pair.old)
        guard FileManager.default.fileExists(atPath: url.path), let kept = readDict(sidecar(url)) else {
            return .failure("kept note or its sidecar is missing")
        }
        guard kept["attachments"] == nil else { return .failure("kept note has attachments") }
        let base = String(pair.old.dropLast(4))
        var sourceID: String?, status: String?
        if let registry {
            let live = registryRows(registry).filter { !SecretaryBookkeeping.flag($0["removed_from_wimm"]) && rowMatches($0, base: base) }
            guard live.count <= 1 else { return .failure(SkipReason(stringLiteral: "registry rows ambiguous (\(live.count) kept)")) }
            sourceID = live.first?["source_id"] as? String; status = live.first?["status"] as? String
        }
        var twins: [Twin] = []
        for name in pair.twins ?? [] {
            switch prepareTwin(name, pair: pair, options: options, new: kept, registry: registry,
                               primarySource: sourceID, primaryStatus: status, marks: marks) {
            case .failure(let why): return .failure(why)
            case .success(let twin): twins.append(twin)
            }
        }
        return .success(Prepared(pair: pair, oldURL: url, newURL: url, transfer: [:], alreadyTransferred: true,
                                 oldBase: base, newBase: base, sourceID: sourceID, twins: twins))
    }

    /// Returns nil when an earlier run already trashed it.
    static func prepareDuplicateImport(_ name: String, pair: Pair, options: Options, marks: [String: AgentMarkStore.Mark],
                                       registry: [String: Any]?) -> Result<URL?, SkipReason> {
        guard name == (name as NSString).lastPathComponent, name.hasPrefix("Wimm_"), name.hasSuffix(".m4a"),
              name != pair.new, name != pair.old else { return .failure("bad duplicate import name") }
        let url = options.recordings.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return trashedCopy(of: url) != nil ? .success(nil) : .failure("duplicate import is missing")
        }
        guard let dict = readDict(sidecar(url)), dict["voiceMemos"] != nil else { return .failure("duplicate is not a Voice Memos import") }
        guard dict["transcription"] == nil, dict["noteCard"] == nil, dict["attachments"] == nil else {
            return .failure("duplicate import has content of its own")
        }
        guard marks[name] == nil else { return .failure("duplicate import has a mark") }
        if let registry, registryRows(registry).contains(where: { rowMatches($0, base: String(name.dropLast(4))) }) {
            return .failure("duplicate import has a registry row")
        }
        return .success(url)
    }

    static func prepareTwin(_ name: String, pair: Pair, options: Options, new: [String: Any], registry: [String: Any]?,
                            primarySource: String?, primaryStatus: String?,
                            marks: [String: AgentMarkStore.Mark]) -> Result<Twin, SkipReason> {
        guard name == (name as NSString).lastPathComponent, name.hasPrefix("Wimm_"), name.hasSuffix(".m4a"),
              name != pair.old, name != pair.new else { return .failure("bad twin file name") }
        let url = options.recordings.appendingPathComponent(name)
        let base = String(name.dropLast(4))
        let kept = ((new["voiceMemos"] as? [String: Any])?["mergedCopies"] as? [[String: Any]] ?? [])
            .contains { $0["file"] as? String == name }
        var twinSource: String?
        if let registry {
            let rows = registryRows(registry).filter { rowMatches($0, base: base) }
            let live = rows.filter { !SecretaryBookkeeping.flag($0["removed_from_wimm"]) }
            let merged = rows.filter { ($0["twin_merge"] as? [String: Any]) != nil }
            if live.count == 1 { twinSource = live[0]["source_id"] as? String }
            else if live.isEmpty, merged.count == 1 { twinSource = merged[0]["source_id"] as? String }
            else if !rows.isEmpty { return .failure(SkipReason(stringLiteral: "twin registry rows ambiguous (\(rows.count))")) }
            if let row = live.first {
                guard row["status"] as? String == primaryStatus || pair.allowStatusMismatch == true else {
                    return .failure(SkipReason(stringLiteral: "twin status differs (\(primaryStatus ?? "none") vs \(row["status"] as? String ?? "none"))"))
                }
                guard twinSource != primarySource else { return .failure("twin has the pair's own source") }
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Gone: only fine when an earlier run kept its copy on the import
            // (or, in place, recorded the merge on its registry row).
            guard kept || (pair.inPlace && registry.map { reg in registryRows(reg).contains {
                rowMatches($0, base: base) && ($0["twin_merge"] as? [String: Any]) != nil } } == true)
            else { return .failure("twin is missing and was not merged") }
            return .success(Twin(name: name, url: url, base: base, sourceID: twinSource, record: nil, present: false))
        }
        guard let twin = readDict(sidecar(url)), let old = readDict(sidecar(options.recordings.appendingPathComponent(pair.old)))
              ?? (kept ? [:] : nil) else { return .failure("twin sidecar unreadable") }
        guard twin["attachments"] == nil else { return .failure("twin has attachments") }
        guard let transcription = twin["transcription"] as? [String: Any], let text = transcription["transcript"] as? String else {
            return .failure("twin has no transcription")
        }
        if let primary = ((old["transcription"] as? [String: Any])?["transcript"] as? String)
            ?? ((new["transcription"] as? [String: Any])?["transcript"] as? String) {
            guard NoteFingerprint.normalized(primary) == NoteFingerprint.normalized(text) else {
                return .failure("twin transcript differs from the pair's")
            }
        }
        if let mark = marks[name], let twinSource, mark.source != twinSource {
            return .failure("twin mark belongs to another source")
        }
        var record: [String: Any] = ["file": name, "transcription": transcription]
        if let twinSource { record["source"] = twinSource }
        if let card = twin["noteCard"] { record["noteCard"] = card }
        return .success(Twin(name: name, url: url, base: base, sourceID: twinSource, record: kept ? nil : record, present: true))
    }

    struct SkipReason: Error, ExpressibleByStringLiteral, CustomStringConvertible {
        let description: String
        init(stringLiteral value: String) { description = value }
    }

    // MARK: - Writes

    static func mergeSidecar(_ item: Prepared, now: Date) throws {
        // `RecordingMetadata` (iPhone detail view, recovery scan) cannot decode a
        // sidecar without these; an import has none. Only missing keys are added.
        let transcription = (item.transfer["transcription"] ?? readDict(sidecar(item.newURL))?["transcription"]) as? [String: Any]
        let measured = (transcription?["audioDurationSec"] as? NSNumber)?.doubleValue
        let stamp = ISO8601DateFormatter().string(from: now)
        let relative = FileStore.relativePath(for: item.newURL)
        try FileStore.mutateSidecar(at: sidecar(item.newURL)) { dict in
            var changed = false
            for (key, value) in item.transfer where dict[key] == nil {
                dict[key] = value; changed = true
            }
            if var voice = dict["voiceMemos"] as? [String: Any] {
                if voice["mergedFromNote"] == nil { voice["mergedFromNote"] = item.pair.old; changed = true }
                var copies = voice["mergedCopies"] as? [[String: Any]] ?? []
                for twin in item.twins {
                    guard let record = twin.record, !copies.contains(where: { $0["file"] as? String == twin.name }) else { continue }
                    copies.append(record); changed = true
                }
                if !copies.isEmpty { voice["mergedCopies"] = copies }
                dict["voiceMemos"] = voice
            }
            if dict["recordingURL"] == nil { dict["recordingURL"] = relative; changed = true }
            if dict["isComplete"] == nil { dict["isComplete"] = true; changed = true }
            if dict["lastSaved"] == nil { dict["lastSaved"] = stamp; changed = true }
            let current = (dict["duration"] as? NSNumber)?.doubleValue
            if current == nil || (current == 0 && (measured ?? 0) > 0) { dict["duration"] = measured ?? 0; changed = true }
            return changed
        }
        // Re-read from disk: what the secretary will actually see. A rerun after
        // the old note went to Trash has nothing left to compare against.
        guard let old = readDict(sidecar(item.oldURL)) else { return }
        let now = NoteFingerprint.read(forRecordingURL: item.newURL)
        let before = NoteFingerprint.make(sidecar: old)
        guard now.text == before.text, now.analysis == before.analysis else {
            throw Failure("fingerprint differs after the transfer; the new sidecar needs a look")
        }
    }

    static func moveMark(_ item: Prepared, store: AgentMarkStore, marks: [String: AgentMarkStore.Mark]) throws {
        // A twin's mark goes with its file; its S now lives in the registry only.
        var dropped: [String: AgentMarkStore.Mark?] = [:]
        for twin in item.twins where marks[twin.name] != nil {
            if let source = twin.sourceID, marks[twin.name]?.source != source { continue }
            dropped[twin.name] = .some(nil)
        }
        if !dropped.isEmpty { try store.update(dropped) }
        if item.pair.inPlace { return } // the kept note's own mark stays as it is
        if marks[item.pair.new] != nil, marks[item.pair.old] == nil { return }
        guard var mark = marks[item.pair.old] else { return } // never marked: nothing to carry
        let oldSidecar = try? Data(contentsOf: sidecar(item.oldURL))
        let newSidecar = try Data(contentsOf: sidecar(item.newURL))
        mark.noteId = item.newURL.stableUUID.uuidString
        // The digest is of the sidecar bytes; refresh it only when it was current.
        if let oldSidecar, mark.sidecarSHA256 == digest(oldSidecar) { mark.sidecarSHA256 = digest(newSidecar) }
        try store.update([item.pair.new: mark, item.pair.old: nil])
    }

    static func patchWorkspace(_ items: [Prepared], workspace: URL, options: Options, stamp: String) throws {
        guard !items.isEmpty else { return }
        let docs = workspace.appendingPathComponent("docs", isDirectory: true)
        let backups = docs.appendingPathComponent(".backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let registryURL = docs.appendingPathComponent("me_structured.sources.json")
        let documentURL = docs.appendingPathComponent("me_structured.md")
        let historyURL = docs.appendingPathComponent("wimm/history.md")
        let tag = "\(stamp)-before-voicememos-merge"

        // Registry: one patch over the changed rows only.
        let registryData = try Data(contentsOf: registryURL)
        let patch = try SecretaryJSONPatch(registryData)
        let members = try patch.members(0..<registryData.count)
        guard let range = members.first(where: { $0.key == "sources" })?.value else { throw Failure("registry has no sources") }
        let spans = try patch.elements(range)
        guard let root = try JSONSerialization.jsonObject(with: registryData) as? [String: Any],
              let rows = root["sources"] as? [[String: Any]], rows.count == spans.count else { throw Failure("registry shape changed") }
        var edits: [(Range<Int>, Data)] = []
        for item in items {
            for twin in item.twins {
                guard let index = rows.firstIndex(where: {
                    rowMatches($0, base: twin.base) && $0["twin_merge"] == nil && !SecretaryBookkeeping.flag($0["removed_from_wimm"])
                }) else { continue } // done earlier, or never registered
                edits.append((spans[index], try SecretaryJSONPatch.encode(twinRow(rows[index], twin: twin, item: item, options: options),
                                                                           indent: patch.indentation(at: spans[index].lowerBound))))
            }
            if item.pair.inPlace { continue } // the kept note's own row does not change
            guard let index = rows.firstIndex(where: {
                rowMatches($0, base: item.oldBase) && !SecretaryBookkeeping.flag($0["removed_from_wimm"])
            }) else { continue } // done earlier
            var row = rows[index]
            let oldSidecarDigest = (try? Data(contentsOf: sidecar(item.oldURL))).map(digest)
            let newDigest = digest(try Data(contentsOf: sidecar(item.newURL)))
            let previousPath = row["path"] as? String
            let previousNoteFile = row["note_file"]
            let previousRecorded = row["recorded_at_local"]
            for key in ["path", "note_file"] {
                if let value = row[key] as? String { row[key] = value.replacingOccurrences(of: item.oldBase, with: item.newBase) }
            }
            if let local = localDate(fromName: item.pair.new) { row["recorded_at_local"] = local }
            if row["previous_path"] == nil, let previousPath { row["previous_path"] = previousPath }
            var replacement: [String: Any] = ["date": isoDay(options.now), "reason":
                "Voice Memos: настоящая дата записи вместо даты импорта 19.10; заметка заменена импортированной копией того же звука"]
            if let previousPath { replacement["previous_path"] = previousPath }
            if let previousNoteFile { replacement["previous_note_file"] = previousNoteFile }
            if let previousRecorded { replacement["previous_recorded_at_local"] = previousRecorded }
            row["voicememos_replacement"] = replacement
            // Digests: only a value that was current for the old sidecar is refreshed.
            for key in ["sha256", "read_sha256"] where (row[key] as? String) == oldSidecarDigest { row[key] = newDigest }
            if var review = row["host_review"] as? [String: Any], (review["read_sha256"] as? String) == oldSidecarDigest {
                review["read_sha256"] = newDigest; row["host_review"] = review
            }
            edits.append((spans[index], try SecretaryJSONPatch.encode(row, indent: patch.indentation(at: spans[index].lowerBound))))
        }
        let newRegistry = try patch.applying(edits)

        // Definition lines in the document and in the Wimm history.
        func relink(_ url: URL) throws -> (String, String)? {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let text = try String(contentsOf: url, encoding: .utf8)
            var lines = text.components(separatedBy: "\n")
            var changed = false
            for index in lines.indices where lines[index].hasPrefix("[S") {
                for item in items {
                    for base in [item.oldBase] + item.twins.map(\.base) where lines[index].contains("/\(base).meta.json") {
                        lines[index] = lines[index].replacingOccurrences(of: "/\(base).meta.json", with: "/\(item.newBase).meta.json")
                        changed = true
                    }
                }
            }
            return changed ? (text, lines.joined(separator: "\n")) : nil
        }
        let document = try relink(documentURL)
        let history = try relink(historyURL)

        // All inputs are ready: back up, then write.
        if !edits.isEmpty { try copy(registryURL, to: backups.appendingPathComponent("me_structured.sources.\(tag).json")) }
        if document != nil { try copy(documentURL, to: backups.appendingPathComponent("me_structured.\(tag).md")) }
        if history != nil { try copy(historyURL, to: backups.appendingPathComponent("wimm-history.\(tag).md")) }
        if !edits.isEmpty { try newRegistry.write(to: registryURL, options: .atomic) }
        if let document { try Data(document.1.utf8).write(to: documentURL, options: .atomic) }
        if let history { try Data(history.1.utf8).write(to: historyURL, options: .atomic) }
    }

    /// The twin's S keeps its status and reading evidence; only where it points changes.
    static func twinRow(_ source: [String: Any], twin: Twin, item: Prepared, options: Options) throws -> [String: Any] {
        var row = source
        let previousPath = row["path"] as? String
        let previousRecorded = row["recorded_at_local"]
        if let path = previousPath { row["path"] = path.replacingOccurrences(of: twin.base, with: item.newBase) }
        // `note_file` stays the twin's own (trashed) name: two rows naming one
        // live note file would make the packet builder refuse that note.
        if let local = localDate(fromName: item.pair.new) { row["recorded_at_local"] = local }
        if row["previous_path"] == nil, let previousPath { row["previous_path"] = previousPath }
        if let primary = item.sourceID {
            var merged = row["merged_with"] as? [String] ?? []
            if !merged.contains(primary) { merged.append(primary) }
            row["merged_with"] = merged
        }
        let day = isoDay(options.now)
        let reason = item.pair.inPlace
            ? "Копия того же звука в импорте 19.10; объединена с \(item.sourceID ?? item.pair.old) в оставшуюся копию \(item.pair.new) (оригинала Voice Memos нет)"
            : "Копия того же звука в импорте 19.10; объединена с \(item.sourceID ?? item.pair.old) в заметку с настоящей датой \(item.pair.new)"
        var removed: [String: Any] = ["date": day, "reason": reason]
        if let twinMeta = readDict(sidecar(twin.url)), let id = (twinMeta["recordingId"] ?? twinMeta["syncId"]) as? String { removed["recording_id"] = id }
        row["removed_from_wimm"] = removed
        var record: [String: Any] = ["date": day, "kept_note": item.pair.new, "trashed_note": twin.name, "reason": reason]
        if let primary = item.sourceID { record["merged_into"] = primary }
        if let previousPath { record["previous_path"] = previousPath }
        if let previousRecorded { record["previous_recorded_at_local"] = previousRecorded }
        row["twin_merge"] = record
        return row
    }

    // MARK: - Helpers

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func sidecar(_ media: URL) -> URL { FileStore.metadataURL(forRecordingURL: media) }

    static func readDict(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func isoDay(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// `Wimm_2015-11-14_12-27-33_…` → `2015-11-14 12:27:33` (the registry's local time).
    static func localDate(fromName name: String) -> String? {
        let parts = name.split(separator: "_")
        guard parts.count >= 3, parts[1].count == 10, parts[2].count == 8 else { return nil }
        return "\(parts[1]) \(parts[2].replacingOccurrences(of: "-", with: ":"))"
    }

    static func loadRegistry(_ workspace: URL) -> [String: Any]? {
        let url = workspace.appendingPathComponent("docs/me_structured.sources.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func registryRows(_ registry: [String: Any]) -> [[String: Any]] { registry["sources"] as? [[String: Any]] ?? [] }

    static func rowMatches(_ row: [String: Any], base: String) -> Bool {
        for key in ["path", "note_file"] {
            guard let value = row[key] as? String else { continue }
            let name = (value as NSString).lastPathComponent
            if name == "\(base).meta.json" || name == "\(base).m4a" || name == base { return true }
        }
        return false
    }

    static func backupFile(_ url: URL, into directory: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try copy(url, to: directory.appendingPathComponent(url.lastPathComponent))
    }

    static func copy(_ source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
