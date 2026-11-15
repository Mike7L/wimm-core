import XCTest
import WimmDomain

/// Moving a note to Trash never deletes a same-name file already there; the
/// note's files move together under one free name and come back intact.
final class RecordingTrashCollisionTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-trash-collision-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", base.path, 1)
        try fm.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
        try fm.createDirectory(at: FileStore.trashDirectory(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("WIMM_BASE_DIR")
        try? fm.removeItem(at: base)
    }

    private func meta(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: url))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeNote(_ name: String, id: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("audio-\(id)".utf8).write(to: url)
        try Data("micro-\(id)".utf8).write(to: FileStore.microURL(forRecordingURL: url))
        try Data(#"{"recordingId":"\#(id)"}"#.utf8).write(to: FileStore.metadataURL(forRecordingURL: url))
        return url
    }

    func testCollisionPicksFreeSuffixedNameForTheWholeGroup() throws {
        let trash = FileStore.trashDirectory()
        let older = try makeNote("note.m4a", id: "OLD", in: trash)
        // `note_1` is taken by an orphan sidecar only: still not free.
        try Data("{}".utf8).write(to: trash.appendingPathComponent("note_1.meta.json"))
        let note = try makeNote("note.m4a", id: "NEW", in: FileStore.recordingsDirectory())

        let trashed = try XCTUnwrap(RecordingTrashSupport.moveToTrash(file: note))

        XCTAssertEqual(trashed.lastPathComponent, "note_2.m4a")
        XCTAssertEqual(try Data(contentsOf: trashed), Data("audio-NEW".utf8))
        XCTAssertEqual(try Data(contentsOf: FileStore.microURL(forRecordingURL: trashed)), Data("micro-NEW".utf8))
        XCTAssertEqual(try meta(trashed)["recordingId"] as? String, "NEW")
        XCTAssertEqual(try meta(trashed)["originalPath"] as? String, note.path)
        XCTAssertEqual(try Data(contentsOf: older), Data("audio-OLD".utf8))
        XCTAssertEqual(try Data(contentsOf: FileStore.microURL(forRecordingURL: older)), Data("micro-OLD".utf8))
        XCTAssertEqual(try meta(older)["recordingId"] as? String, "OLD")
        XCTAssertFalse(fm.fileExists(atPath: note.path))

        let restored = try XCTUnwrap(RecordingTrashSupport.restoreFromTrash(file: trashed))
        XCTAssertEqual(restored.lastPathComponent, "note.m4a")
        XCTAssertEqual(try meta(restored)["recordingId"] as? String, "NEW")
        XCTAssertTrue(fm.fileExists(atPath: FileStore.microURL(forRecordingURL: restored).path))
        for key in RecordingTrashSupport.markerKeys { XCTAssertNil(try meta(restored)[key], key) }
        XCTAssertTrue(fm.fileExists(atPath: older.path), "restoring one never touches the other")
    }

    func testRestoreOntoATakenNameKeepsTheGroupTogether() throws {
        let note = try makeNote("dup.m4a", id: "A", in: FileStore.recordingsDirectory())
        let trashed = try XCTUnwrap(RecordingTrashSupport.moveToTrash(file: note))
        // A new note took the name meanwhile, without a micro copy.
        let live = FileStore.recordingsDirectory().appendingPathComponent("dup.m4a")
        try Data("live".utf8).write(to: live)

        let restored = try XCTUnwrap(RecordingTrashSupport.restoreFromTrash(file: trashed))

        XCTAssertEqual(restored.lastPathComponent, "dup_1.m4a")
        XCTAssertEqual(try Data(contentsOf: live), Data("live".utf8))
        XCTAssertEqual(try meta(restored)["recordingId"] as? String, "A")
        XCTAssertEqual(try Data(contentsOf: FileStore.microURL(forRecordingURL: restored)), Data("micro-A".utf8))
        XCTAssertFalse(fm.fileExists(atPath: FileStore.microURL(forRecordingURL: live).path),
                       "the restored micro copy never lands next to the other note")
    }

    func testFailedMoveRollsBackEveryFile() throws {
        let note = try makeNote("rollback.m4a", id: "R", in: FileStore.recordingsDirectory())
        let failing = FailingSecondMove()
        let result = RecordingTrashSupport.moveToTrash(file: note, fileManager: failing)

        XCTAssertNil(result)
        XCTAssertEqual(try Data(contentsOf: note), Data("audio-R".utf8))
        XCTAssertTrue(fm.fileExists(atPath: FileStore.microURL(forRecordingURL: note).path))
        XCTAssertEqual(try meta(note)["recordingId"] as? String, "R")
        let left = try fm.contentsOfDirectory(atPath: FileStore.trashDirectory().path)
        XCTAssertTrue(left.isEmpty, "\(left)")
    }
}

/// Fails the second move into Trash, so one file already moved must go back.
private final class FailingSecondMove: FileManager, @unchecked Sendable {
    private var moves = 0
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if dstURL.path.contains("/Trash/") {
            moves += 1
            if moves == 2 { throw CocoaError(.fileWriteUnknown) }
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
