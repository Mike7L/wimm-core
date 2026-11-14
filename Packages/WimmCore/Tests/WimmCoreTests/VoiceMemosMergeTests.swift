import CryptoKit
import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

final class VoiceMemosMergeTests: XCTestCase {
    var root: URL!
    var rec: URL!
    var state: URL!
    var me: URL!
    var backups: URL!
    let oldName = "Wimm_2026-10-19_19-26-12_11C4B52D.m4a"
    let newName = "Wimm_2015-11-14_12-27-33_2C2DF68C.m4a"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-merge-\(UUID().uuidString)")
        rec = root.appendingPathComponent("Recordings")
        state = root.appendingPathComponent("AgentState")
        me = root.appendingPathComponent("_ME")
        backups = root.appendingPathComponent("repair-backups")
        for dir in [rec!, state!, me.appendingPathComponent("docs/wimm"), backups!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func write(_ dict: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    private func sidecar(_ name: String) -> URL { rec.appendingPathComponent(name.replacingOccurrences(of: ".m4a", with: ".meta.json")) }

    private func setUpPair(newTranscription: [String: Any]? = nil) throws {
        try Data("old".utf8).write(to: rec.appendingPathComponent(oldName))
        try Data("old-micro".utf8).write(to: rec.appendingPathComponent(oldName.replacingOccurrences(of: ".m4a", with: "_micro.m4a")))
        try Data("new".utf8).write(to: rec.appendingPathComponent(newName))
        try write(["duration": 0, "syncId": "OLD-SYNC", "origin": ["device": "iPhone15,2"],
                   "transcription": ["transcript": "привет мир", "provider": "parakeet", "audioDurationSec": 12.5],
                   "noteCard": ["title": "Привет", "summary": "про мир"]], sidecar(oldName))
        var new: [String: Any] = ["syncId": "NEW-SYNC", "timestamp": "2015-11-14T11:27:33Z",
                                  "voiceMemos": ["file": "20151114 122733-2C2DF68C.m4a"]]
        if let newTranscription { new["transcription"] = newTranscription }
        try write(new, sidecar(newName))

        let oldDict = try XCTUnwrap(VoiceMemosMerge.readDict(sidecar(oldName)))
        let fp = NoteFingerprint.make(sidecar: oldDict)
        let mark = AgentMarkStore.Mark(status: .applied, source: "S10", markedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                       noteId: rec.appendingPathComponent(oldName).stableUUID.uuidString,
                                       sidecarSHA256: VoiceMemosMerge.digest(try Data(contentsOf: sidecar(oldName))),
                                       text: fp.text, analysis: fp.analysis, wording: fp.wording)
        try AgentMarkStore(directory: state).update([oldName: mark])

        let oldBase = String(oldName.dropLast(4))
        let oldDigest = VoiceMemosMerge.digest(try Data(contentsOf: sidecar(oldName)))
        let registry: [String: Any] = ["source_count": 2, "sources": [
            ["source_id": "S10", "status": "applied", "recorded_at_local": "2026-10-19 19:26:12",
             "path": "../recordings/\(oldBase).meta.json", "sha256": oldDigest, "read_sha256": oldDigest],
            ["source_id": "S11", "status": "noise", "recorded_at_local": "2026-10-19 19:30:00",
             "path": "../recordings/Wimm_2026-10-19_19-30-00_AAAAAAAA.meta.json"]
        ]]
        try write(registry, me.appendingPathComponent("docs/me_structured.sources.json"))
        try "Text [S10].\n\n[S10]: ../recordings/\(oldBase).meta.json\n[S11]: ../recordings/Wimm_2026-10-19_19-30-00_AAAAAAAA.meta.json\n"
            .write(to: me.appendingPathComponent("docs/me_structured.md"), atomically: true, encoding: .utf8)
        try "[S10]: ../../recordings/\(oldBase).meta.json\n"
            .write(to: me.appendingPathComponent("docs/wimm/history.md"), atomically: true, encoding: .utf8)
    }

    private func options(apply: Bool, workspace: Bool = true) -> VoiceMemosMerge.Options {
        .init(recordings: rec, agentState: state, workspace: workspace ? me : nil, backupDirectory: backups, apply: apply,
              now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private let pair = VoiceMemosMerge.Pair(old: "Wimm_2026-10-19_19-26-12_11C4B52D.m4a", new: "Wimm_2015-11-14_12-27-33_2C2DF68C.m4a")

    func testDryRunChangesNothing() throws {
        try setUpPair()
        let before = try Data(contentsOf: sidecar(newName))
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: false))
        XCTAssertEqual(rows.first?.outcome, .wouldMerge)
        XCTAssertEqual(rows.first?.source, "S10")
        XCTAssertEqual(try Data(contentsOf: sidecar(newName)), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(oldName).path))
        XCTAssertNotNil(AgentMarkStore(directory: state).mark(forFile: oldName))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: backups.path).isEmpty)
    }

    func testApplyMovesEverythingAndIsIdempotent() throws {
        try setUpPair()
        var rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        XCTAssertEqual(rows.map(\.outcome), [.merged])

        let new = try XCTUnwrap(VoiceMemosMerge.readDict(sidecar(newName)))
        XCTAssertEqual((new["transcription"] as? [String: Any])?["transcript"] as? String, "привет мир")
        XCTAssertNotNil(new["noteCard"]); XCTAssertNotNil(new["origin"])
        XCTAssertEqual(new["duration"] as? Double, 12.5, "duration comes from the measured transcription, not the old placeholder 0")
        XCTAssertEqual(new["isComplete"] as? Bool, true)
        XCTAssertNotNil(new["lastSaved"])
        let decoded = try RecordingMetadata.load(for: rec.appendingPathComponent(newName))
        XCTAssertEqual(decoded.transcription, "привет мир")
        XCTAssertEqual(decoded.duration, 12.5)
        XCTAssertEqual(new["syncId"] as? String, "NEW-SYNC")

        // Marks follow the note: new key, new id, fresh digest, same fingerprint.
        let store = AgentMarkStore(directory: state)
        XCTAssertNil(store.mark(forFile: oldName))
        let mark = try XCTUnwrap(store.mark(forFile: newName))
        let url = rec.appendingPathComponent(newName)
        XCTAssertEqual(mark.noteId, url.stableUUID.uuidString)
        XCTAssertEqual(mark.sidecarSHA256, VoiceMemosMerge.digest(try Data(contentsOf: sidecar(newName))))
        let fp = NoteFingerprint.read(forRecordingURL: url)
        XCTAssertEqual(mark.text, fp.text); XCTAssertEqual(mark.analysis, fp.analysis)
        XCTAssertEqual(mark.source, "S10"); XCTAssertEqual(mark.status, .applied)

        // Registry: path, date, previous path, digests; the other row untouched.
        let registry = try XCTUnwrap(VoiceMemosMerge.loadRegistry(me))
        let rowsJSON = VoiceMemosMerge.registryRows(registry)
        let s10 = try XCTUnwrap(rowsJSON.first { $0["source_id"] as? String == "S10" })
        XCTAssertEqual(s10["path"] as? String, "../recordings/Wimm_2015-11-14_12-27-33_2C2DF68C.meta.json")
        XCTAssertEqual(s10["recorded_at_local"] as? String, "2015-11-14 12:27:33")
        XCTAssertEqual(s10["previous_path"] as? String, "../recordings/Wimm_2026-10-19_19-26-12_11C4B52D.meta.json")
        XCTAssertEqual(s10["sha256"] as? String, mark.sidecarSHA256)
        XCTAssertNotNil(s10["voicememos_replacement"])
        let s11 = try XCTUnwrap(rowsJSON.first { $0["source_id"] as? String == "S11" })
        XCTAssertEqual(s11["recorded_at_local"] as? String, "2026-10-19 19:30:00")

        // Definitions in the document and the history; backups next to them.
        let doc = try String(contentsOf: me.appendingPathComponent("docs/me_structured.md"), encoding: .utf8)
        XCTAssertTrue(doc.contains("[S10]: ../recordings/Wimm_2015-11-14_12-27-33_2C2DF68C.meta.json"))
        XCTAssertTrue(doc.contains("Text [S10]."))
        XCTAssertTrue(doc.contains("AAAAAAAA.meta.json"))
        let history = try String(contentsOf: me.appendingPathComponent("docs/wimm/history.md"), encoding: .utf8)
        XCTAssertTrue(history.contains("../../recordings/Wimm_2015-11-14_12-27-33_2C2DF68C.meta.json"))
        let docBackups = try FileManager.default.contentsOfDirectory(atPath: me.appendingPathComponent("docs/.backups").path)
        XCTAssertEqual(docBackups.count, 3)

        // The old note is in Trash with its files; nothing of it is left in Recordings.
        XCTAssertFalse(FileManager.default.fileExists(atPath: rec.appendingPathComponent(oldName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar(oldName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: FileStore.trashDirectory().appendingPathComponent(oldName).path))
        let run = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        let log = try Data(contentsOf: backups.appendingPathComponent(run).appendingPathComponent("trash_log.json"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: log) as? [[String]])?.count, 1)

        // A rerun finds everything done and changes nothing.
        let registryBytes = try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json"))
        rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        XCTAssertEqual(rows.map(\.outcome), [.alreadyDone])
        XCTAssertEqual(try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json")), registryBytes)
        XCTAssertNotNil(store.mark(forFile: newName))
    }

    /// 13.11 a run was killed mid-way and its trash log was never written. A
    /// rerun must log the old notes the killed run already moved to Trash.
    func testRerunAfterLostLogRebuildsTheTrashLog() throws {
        try setUpPair()
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [pair], options: options(apply: true)).map(\.outcome), [.merged])
        let first = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        // Simulate the interrupted run: its log is gone.
        try FileManager.default.removeItem(at: backups.appendingPathComponent(first).appendingPathComponent("trash_log.json"))

        var later = options(apply: true)
        later.now = Date(timeIntervalSince1970: 1_800_000_600)
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [pair], options: later).map(\.outcome), [.alreadyDone])
        let second = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first { $0 != first })
        let data = try Data(contentsOf: backups.appendingPathComponent(second).appendingPathComponent("trash_log.json"))
        let log = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String]])
        XCTAssertEqual(log, [[rec.appendingPathComponent(oldName).path,
                              FileStore.trashDirectory().appendingPathComponent(oldName).path]])
        // The format the tombstone step reads.
        XCTAssertEqual(try TrashTombstoneBackfill.trashedNames(fromLog: backups.appendingPathComponent(second)
            .appendingPathComponent("trash_log.json")), [oldName])
    }

    /// A Trash copy with the same name but another origin is not ours to log.
    func testTrashedCopyNeedsMatchingOriginalPath() throws {
        let trash = FileStore.trashDirectory()
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let name = "Wimm_2026-10-19_10-00-00_DEADBEEF.m4a"
        try Data("x".utf8).write(to: trash.appendingPathComponent(name))
        try write(["originalPath": "/elsewhere/\(name)"], trash.appendingPathComponent(name.replacingOccurrences(of: ".m4a", with: ".meta.json")))
        XCTAssertNil(VoiceMemosMerge.trashedCopy(of: rec.appendingPathComponent(name)))
        try write(["originalPath": rec.appendingPathComponent(name).path],
                  trash.appendingPathComponent(name.replacingOccurrences(of: ".m4a", with: ".meta.json")))
        XCTAssertEqual(VoiceMemosMerge.trashedCopy(of: rec.appendingPathComponent(name))?.lastPathComponent, name)
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: trash.appendingPathComponent(name.replacingOccurrences(of: ".m4a", with: ".meta.json")))
    }

    func testConflictingTranscriptionSkipsTheWholePair() throws {
        try setUpPair(newTranscription: ["transcript": "другое"])
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        guard case .skipped(let why) = rows.first?.outcome else { return XCTFail("expected skip, got \(String(describing: rows.first?.outcome))") }
        XCTAssertTrue(why.contains("conflict"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(oldName).path))
        XCTAssertNotNil(AgentMarkStore(directory: state).mark(forFile: oldName))
        XCTAssertNil(VoiceMemosMerge.readDict(sidecar(newName))?["noteCard"])
    }

    func testRegistryProblemSkipsBeforeAnyWrite() throws {
        try setUpPair()
        // A second row for the same old note makes the source ambiguous.
        var registry = try XCTUnwrap(VoiceMemosMerge.loadRegistry(me))
        var rows = VoiceMemosMerge.registryRows(registry)
        rows.append(["source_id": "S99", "status": "noise", "path": rows[0]["path"] as Any])
        registry["sources"] = rows
        try write(registry, me.appendingPathComponent("docs/me_structured.sources.json"))
        let result = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        guard case .skipped(let why) = result.first?.outcome else { return XCTFail("expected skip") }
        XCTAssertTrue(why.contains("ambiguous"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(oldName).path))
        XCTAssertNil(VoiceMemosMerge.readDict(sidecar(newName))?["transcription"])
    }

    func testApplyNeedsWorkspace() throws {
        try setUpPair()
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true, workspace: false))
        guard case .failed = rows.first?.outcome else { return XCTFail("expected failure") }
        XCTAssertNil(VoiceMemosMerge.readDict(sidecar(newName))?["transcription"])
    }

    func testNonImportTargetIsRefused() throws {
        try setUpPair()
        var new = try XCTUnwrap(VoiceMemosMerge.readDict(sidecar(newName)))
        new.removeValue(forKey: "voiceMemos")
        try write(new, sidecar(newName))
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        guard case .skipped = rows.first?.outcome else { return XCTFail("expected skip") }
    }
}
