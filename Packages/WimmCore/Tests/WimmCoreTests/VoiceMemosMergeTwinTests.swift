import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

/// Two 19.10 copies of one sound, each with its own S, merged into one Voice Memos import.
final class VoiceMemosMergeTwinTests: XCTestCase {
    var root: URL!
    var rec: URL!
    var state: URL!
    var me: URL!
    var backups: URL!
    let oldName = "Wimm_2026-10-19_18-47-13_B1359D6A.m4a"
    let twinName = "Wimm_2026-10-19_19-26-15_F88C3082.m4a"
    let newName = "Wimm_2026-05-05_13-17-16_ABCDEF12.m4a"
    var pair: VoiceMemosMerge.Pair { .init(old: oldName, new: newName, twins: [twinName]) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vm-twins-\(UUID().uuidString)")
        rec = root.appendingPathComponent("Recordings")
        state = root.appendingPathComponent("AgentState")
        me = root.appendingPathComponent("_ME")
        backups = root.appendingPathComponent("repair-backups")
        for dir in [rec!, state!, me.appendingPathComponent("docs/wimm"), backups!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        for name in [oldName, twinName] {
            let trash = FileStore.trashDirectory().appendingPathComponent(name)
            try? FileManager.default.removeItem(at: trash)
            try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: trash))
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ dict: [String: Any], _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }
    private func sidecar(_ name: String) -> URL { FileStore.metadataURL(forRecordingURL: rec.appendingPathComponent(name)) }
    private func base(_ name: String) -> String { String(name.dropLast(4)) }

    private func mark(_ name: String, _ source: String, _ status: AgentMarkStore.Mark.Status) throws -> AgentMarkStore.Mark {
        let fp = NoteFingerprint.make(sidecar: try XCTUnwrap(VoiceMemosMerge.readDict(sidecar(name))))
        return AgentMarkStore.Mark(status: status, source: source, markedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   noteId: rec.appendingPathComponent(name).stableUUID.uuidString,
                                   sidecarSHA256: VoiceMemosMerge.digest(try Data(contentsOf: sidecar(name))),
                                   text: fp.text, analysis: fp.analysis, wording: fp.wording)
    }

    private func makeGroup(twinStatus: String = "applied", twinText: String = "Спор с Верой, поездка на 10 дней.") throws {
        for name in [oldName, twinName, newName] { try Data(name.utf8).write(to: rec.appendingPathComponent(name)) }
        try Data("micro".utf8).write(to: rec.appendingPathComponent(base(twinName) + "_micro.m4a"))
        try write(["duration": 0, "syncId": "OLD", "origin": ["device": "iPhone15,2"],
                   "transcription": ["transcript": "Спор с Верой: поездка на 10 дней", "provider": "parakeet", "audioDurationSec": 30.0,
                                     "previousRuns": [["transcript": "облачный вариант", "provider": "gemini"]]],
                   "noteCard": ["title": "Спор с Верой", "summary": "про поездку", "refined_text": "Спор."]], sidecar(oldName))
        try write(["duration": 0, "syncId": "TWIN", "recordingId": "TWIN-REC", "origin": ["device": "iPhone15,2"],
                   "transcription": ["transcript": twinText, "provider": "parakeet", "audioDurationSec": 30.0],
                   "noteCard": ["title": "Новая запись 7"]], sidecar(twinName))
        try write(["syncId": "NEW", "timestamp": "2026-05-05T11:17:16Z", "voiceMemos": ["file": "20260505 131716-ABCDEF12.m4a"]],
                  sidecar(newName))
        try AgentMarkStore(directory: state).update([oldName: try mark(oldName, "S419", .applied),
                                                     twinName: try mark(twinName, "S898", twinStatus == "noise" ? .noise : .applied)])
        let registry: [String: Any] = ["source_count": 3, "counts": ["applied": twinStatus == "applied" ? 2 : 1, "noise": twinStatus == "noise" ? 1 : 0],
            "sources": [
                ["source_id": "S419", "status": "applied", "recorded_at_local": "2026-10-19 18:47:13",
                 "path": "../recordings/\(base(oldName)).meta.json", "note_file": oldName],
                ["source_id": "S898", "status": twinStatus, "recorded_at_local": "2026-10-19 19:26:15", "reason": "Прочитан полный текст.",
                 "path": "../recordings/\(base(twinName)).meta.json", "note_file": twinName],
                ["source_id": "S11", "status": "noise", "path": "../recordings/Wimm_2026-10-19_19-30-00_AAAAAAAA.meta.json"],
            ]]
        try write(registry, me.appendingPathComponent("docs/me_structured.sources.json"))
        try "Спор [S419][S898].\n\n[S419]: ../recordings/\(base(oldName)).meta.json\n[S898]: ../recordings/\(base(twinName)).meta.json\n"
            .write(to: me.appendingPathComponent("docs/me_structured.md"), atomically: true, encoding: .utf8)
    }

    private func options(apply: Bool) -> VoiceMemosMerge.Options {
        .init(recordings: rec, agentState: state, workspace: me, backupDirectory: backups, apply: apply,
              now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func registryRow(_ id: String) throws -> [String: Any] {
        try XCTUnwrap(VoiceMemosMerge.registryRows(try XCTUnwrap(VoiceMemosMerge.loadRegistry(me)))
            .first { $0["source_id"] as? String == id })
    }

    func testDryRunNamesBothSourcesAndWritesNothing() throws {
        try makeGroup()
        let before = try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json"))
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: false))
        XCTAssertEqual(rows.map(\.outcome), [.wouldMerge])
        XCTAssertEqual(rows.first?.source, "S419")
        XCTAssertEqual(rows.first?.twinSources, ["S898"])
        XCTAssertEqual(try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json")), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(twinName).path))
    }

    func testApplyPointsBothSourcesAtTheImportAndIsIdempotent() throws {
        try makeGroup()
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [pair], options: options(apply: true)).map(\.outcome), [.merged])

        // The import holds the primary copy's analysis; the twin is kept outside the fingerprint.
        let newURL = rec.appendingPathComponent(newName)
        let new = try XCTUnwrap(VoiceMemosMerge.readDict(sidecar(newName)))
        XCTAssertEqual((new["noteCard"] as? [String: Any])?["title"] as? String, "Спор с Верой")
        let copies = try XCTUnwrap((new["voiceMemos"] as? [String: Any])?["mergedCopies"] as? [[String: Any]])
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(copies[0]["file"] as? String, twinName)
        XCTAssertEqual(copies[0]["source"] as? String, "S898")
        XCTAssertEqual((copies[0]["noteCard"] as? [String: Any])?["title"] as? String, "Новая запись 7")
        XCTAssertNotNil(copies[0]["transcription"])

        // Marks: the primary's moved and still matches; the twin's is gone.
        let store = AgentMarkStore(directory: state)
        XCTAssertNil(store.mark(forFile: oldName)); XCTAssertNil(store.mark(forFile: twinName))
        let mark = try XCTUnwrap(store.mark(forFile: newName))
        XCTAssertEqual(mark.source, "S419")
        let fp = NoteFingerprint.read(forRecordingURL: newURL)
        XCTAssertEqual(mark.text, fp.text); XCTAssertEqual(mark.analysis, fp.analysis); XCTAssertEqual(mark.wording, fp.wording)

        // Registry: both S point at the import; the twin keeps its status and its own note_file.
        let newPath = "../recordings/\(base(newName)).meta.json"
        let s419 = try registryRow("S419"), s898 = try registryRow("S898")
        XCTAssertEqual(s419["path"] as? String, newPath)
        XCTAssertEqual(s898["path"] as? String, newPath)
        XCTAssertEqual(s898["note_file"] as? String, twinName, "two live rows must never name one note file")
        XCTAssertEqual(s898["status"] as? String, "applied")
        XCTAssertEqual(s898["reason"] as? String, "Прочитан полный текст.")
        XCTAssertEqual(s898["merged_with"] as? [String], ["S419"])
        XCTAssertEqual(s898["recorded_at_local"] as? String, "2026-05-05 13:17:16")
        XCTAssertEqual(s898["previous_path"] as? String, "../recordings/\(base(twinName)).meta.json")
        XCTAssertEqual((s898["removed_from_wimm"] as? [String: Any])?["recording_id"] as? String, "TWIN-REC")
        XCTAssertEqual((s898["twin_merge"] as? [String: Any])?["merged_into"] as? String, "S419")
        let registry = try XCTUnwrap(VoiceMemosMerge.loadRegistry(me))
        XCTAssertEqual(registry["counts"] as? [String: Int], ["applied": 2, "noise": 0], "statuses and counts unchanged")

        // Document: both definitions lead to the import, prose untouched.
        let doc = try String(contentsOf: me.appendingPathComponent("docs/me_structured.md"), encoding: .utf8)
        XCTAssertTrue(doc.contains("[S419]: \(newPath)")); XCTAssertTrue(doc.contains("[S898]: \(newPath)"))
        XCTAssertTrue(doc.contains("Спор [S419][S898]."))

        // Both copies (and the twin's _micro) in Trash; the log names both for tombstones.
        for name in [oldName, twinName, base(twinName) + "_micro.m4a"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: rec.appendingPathComponent(name).path), name)
        }
        let run = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        let logURL = backups.appendingPathComponent(run).appendingPathComponent("trash_log.json")
        XCTAssertEqual(Set(try TrashTombstoneBackfill.trashedNames(fromLog: logURL)), [oldName, twinName])
        let backedUp = try FileManager.default.contentsOfDirectory(atPath: backups.appendingPathComponent(run).path)
        XCTAssertTrue(backedUp.contains(base(twinName) + ".meta.json"))

        // A rerun is a no-op.
        let registryBytes = try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json"))
        let newBytes = try Data(contentsOf: sidecar(newName))
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [pair], options: options(apply: true)).map(\.outcome), [.alreadyDone])
        XCTAssertEqual(try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json")), registryBytes)
        XCTAssertEqual(try Data(contentsOf: sidecar(newName)), newBytes)
    }

    func testDifferentStatusIsLeftForTheUser() throws {
        try makeGroup(twinStatus: "noise")
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        guard case .skipped(let why) = rows.first?.outcome else { return XCTFail("expected skip") }
        XCTAssertTrue(why.contains("status differs"), why)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(twinName).path))
        XCTAssertNil(VoiceMemosMerge.readDict(sidecar(newName))?["transcription"])
        XCTAssertNotNil(AgentMarkStore(directory: state).mark(forFile: twinName))
    }

    func testUserAllowedStatusMismatchKeepsBothStatuses() throws {
        try makeGroup(twinStatus: "noise")
        var allowed = pair; allowed.allowStatusMismatch = true
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [allowed], options: options(apply: true)).map(\.outcome), [.merged])
        XCTAssertEqual(try registryRow("S419")["status"] as? String, "applied")
        let twin = try registryRow("S898")
        XCTAssertEqual(twin["status"] as? String, "noise")
        XCTAssertNotNil(twin["removed_from_wimm"])
        XCTAssertEqual(AgentMarkStore(directory: state).mark(forFile: newName)?.status, .applied)
        XCTAssertNil(AgentMarkStore(directory: state).mark(forFile: twinName))
    }

    func testDifferentTranscriptIsRefused() throws {
        try makeGroup(twinText: "совсем другой текст")
        let rows = VoiceMemosMerge.run(pairs: [pair], options: options(apply: true))
        guard case .skipped(let why) = rows.first?.outcome else { return XCTFail("expected skip") }
        XCTAssertTrue(why.contains("transcript differs"), why)
        XCTAssertNil(VoiceMemosMerge.readDict(sidecar(newName))?["transcription"])
    }

    /// No Voice Memos original: the analysed copy stays untouched, the twin joins it.
    func testKeepInPlaceLeavesTheKeptNoteAndMergesTheTwin() throws {
        try makeGroup()
        let kept = VoiceMemosMerge.Pair(old: oldName, new: oldName, twins: [twinName], keepInPlace: true)
        let keptBytes = try Data(contentsOf: sidecar(oldName))
        let keptMark = AgentMarkStore(directory: state).mark(forFile: oldName)
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [kept], options: options(apply: true)).map(\.outcome), [.merged])

        XCTAssertEqual(try Data(contentsOf: sidecar(oldName)), keptBytes, "kept sidecar is not written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(oldName).path))
        XCTAssertEqual(AgentMarkStore(directory: state).mark(forFile: oldName), keptMark)
        XCTAssertNil(AgentMarkStore(directory: state).mark(forFile: twinName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rec.appendingPathComponent(twinName).path))

        let keptPath = "../recordings/\(base(oldName)).meta.json"
        let s419 = try registryRow("S419"), s898 = try registryRow("S898")
        XCTAssertEqual(s419["path"] as? String, keptPath)
        XCTAssertNil(s419["voicememos_replacement"])
        XCTAssertEqual(s898["path"] as? String, keptPath)
        XCTAssertEqual(s898["note_file"] as? String, twinName)
        XCTAssertEqual(s898["merged_with"] as? [String], ["S419"])
        XCTAssertNotNil(s898["removed_from_wimm"])
        let doc = try String(contentsOf: me.appendingPathComponent("docs/me_structured.md"), encoding: .utf8)
        XCTAssertTrue(doc.contains("[S898]: \(keptPath)"))

        let run = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        XCTAssertEqual(try TrashTombstoneBackfill.trashedNames(fromLog: backups.appendingPathComponent(run)
            .appendingPathComponent("trash_log.json")), [twinName], "only the twin is trashed")

        let registryBytes = try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json"))
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [kept], options: options(apply: true)).map(\.outcome), [.alreadyDone])
        XCTAssertEqual(try Data(contentsOf: me.appendingPathComponent("docs/me_structured.sources.json")), registryBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(oldName).path))
    }

    /// A second Voice Memos import of the same sound with nothing of its own goes to Trash too.
    func testEmptyDuplicateImportIsTrashedAndLogged() throws {
        try makeGroup()
        let dup = "Wimm_2026-05-05_13-17-16_99999999.m4a"
        try Data("dup".utf8).write(to: rec.appendingPathComponent(dup))
        try write(["syncId": "DUP", "voiceMemos": ["file": "20260505 131716-99999999.m4a"]], sidecar(dup))
        var withDup = pair; withDup.duplicateImports = [dup]
        XCTAssertEqual(VoiceMemosMerge.run(pairs: [withDup], options: options(apply: true)).map(\.outcome), [.merged])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rec.appendingPathComponent(dup).path))
        let run = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: backups.path).first)
        XCTAssertEqual(Set(try TrashTombstoneBackfill.trashedNames(fromLog: backups.appendingPathComponent(run)
            .appendingPathComponent("trash_log.json"))), [oldName, twinName, dup])
        try? FileManager.default.removeItem(at: FileStore.trashDirectory().appendingPathComponent(dup))
        try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: FileStore.trashDirectory().appendingPathComponent(dup)))
    }

    func testDuplicateImportWithContentIsRefused() throws {
        try makeGroup()
        let dup = "Wimm_2026-05-05_13-17-16_99999999.m4a"
        try Data("dup".utf8).write(to: rec.appendingPathComponent(dup))
        try write(["voiceMemos": ["file": "x.m4a"], "transcription": ["transcript": "своё"]], sidecar(dup))
        var withDup = pair; withDup.duplicateImports = [dup]
        guard case .skipped(let why) = VoiceMemosMerge.run(pairs: [withDup], options: options(apply: true)).first?.outcome
        else { return XCTFail("expected skip") }
        XCTAssertTrue(why.contains("content of its own"), why)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rec.appendingPathComponent(twinName).path))
    }

    /// An old pairs file without `twins` still decodes.
    func testPairsWithoutTwinsDecode() throws {
        let url = root.appendingPathComponent("pairs.json")
        try Data(#"{"pairs":[{"old":"a.m4a","new":"b.m4a"}]}"#.utf8).write(to: url)
        XCTAssertEqual(try VoiceMemosMerge.load(pairsAt: url), [.init(old: "a.m4a", new: "b.m4a")])
    }
}
