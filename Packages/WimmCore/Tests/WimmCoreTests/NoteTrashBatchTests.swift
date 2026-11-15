import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class NoteTrashBatchTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-trash-batch-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", base.path, 1)
        try FileStore.ensureDirectoryExists()
    }

    override func tearDownWithError() throws {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    private func makeNote(_ name: String) throws -> URL {
        let url = FileStore.recordingsDirectory().appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        try Data(#"{"duration":0.7}"#.utf8).write(to: FileStore.metadataURL(forRecordingURL: url))
        return url
    }

    func testOnlyListedNotesMoveWithSidecarsAndAreMarked() throws {
        let a = try makeNote("Wimm_2026-01-02_03-04-05_AAAA0001.aac")
        let keep = try makeNote("Wimm_2026-01-02_03-04-06_AAAA0002.aac")
        let plan = NoteTrashBatch.plan(names: [a.lastPathComponent])
        XCTAssertEqual(plan.notes.map(\.lastPathComponent), [a.lastPathComponent])
        XCTAssertTrue(plan.rejected.isEmpty)

        let result = NoteTrashBatch.apply(plan)
        XCTAssertEqual(result.trashed.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileStore.metadataURL(forRecordingURL: a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep.path))

        let trashed = try XCTUnwrap(result.trashed.first)
        XCTAssertEqual(trashed.deletingLastPathComponent().standardizedFileURL,
                       FileStore.trashDirectory().standardizedFileURL)
        let meta = try JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: trashed))) as? [String: Any]
        XCTAssertEqual(meta?["trashed"] as? Bool, true)
        XCTAssertEqual(meta?["originalPath"] as? String, a.path)
    }

    func testRejectsPathsMissingSidecarsAndDuplicates() throws {
        let a = try makeNote("Wimm_2026-01-02_03-04-05_AAAA0003.aac")
        let plan = NoteTrashBatch.plan(names: [
            a.lastPathComponent, a.lastPathComponent,
            "../escape.aac",
            "Wimm_2026-01-02_03-04-05_AAAA0003.meta.json",
            "missing.aac",
            "",
        ])
        XCTAssertEqual(plan.notes.count, 1)
        XCTAssertEqual(plan.rejected.map(\.reason), [.duplicate, .notAName, .notANote, .notFound])
    }
}
