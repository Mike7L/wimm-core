import XCTest
@testable import WimmInfrastructure

final class VoiceMemosAutoImporterTests: XCTestCase {

    private var tempDir: URL!
    private var memosDir: URL!
    private var recordingsDir: URL!
    private var stateURL: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceMemosAutoImporterTests-\(UUID().uuidString)")
        memosDir = tempDir.appendingPathComponent("VoiceMemos")
        recordingsDir = tempDir.appendingPathComponent("Recordings")
        stateURL = tempDir.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: memosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeImporter() -> VoiceMemosAutoImporter {
        VoiceMemosAutoImporter(folder: memosDir, stateURL: stateURL, recordingsDirectory: recordingsDir)
    }

    @discardableResult
    private func writeMemo(_ name: String, modified: Date) throws -> URL {
        let url = memosDir.appendingPathComponent(name)
        try Data("audio".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testPendingReturnsOnlyStableM4AFiles() async throws {
        let old = Date().addingTimeInterval(-3600)
        try writeMemo("stable.m4a", modified: old)
        try writeMemo("fresh.m4a", modified: Date())
        try writeMemo("waveform.dat", modified: old)

        let scan = await makeImporter().pendingFiles()

        XCTAssertFalse(scan.accessDenied)
        XCTAssertEqual(scan.pending.map(\.lastPathComponent), ["stable.m4a"])
    }

    func testMarkImportedIsPersistedAcrossInstances() async throws {
        let old = Date().addingTimeInterval(-3600)
        let memo = try writeMemo("memo.m4a", modified: old)

        await makeImporter().markImported(sources: [memo])

        let scan = await makeImporter().pendingFiles()
        XCTAssertTrue(scan.pending.isEmpty)
    }

    func testPendingSortsOldestFirst() async throws {
        try writeMemo("newer.m4a", modified: Date().addingTimeInterval(-3600))
        try writeMemo("older.m4a", modified: Date().addingTimeInterval(-7200))

        let scan = await makeImporter().pendingFiles()
        XCTAssertEqual(scan.pending.map(\.lastPathComponent), ["older.m4a", "newer.m4a"])
    }

    func testBackfillSkipsManuallyImportedMemos() async throws {
        let old = Date().addingTimeInterval(-3600)
        try writeMemo("already-imported.m4a", modified: old)
        try writeMemo("new.m4a", modified: old)

        let meta: [String: Any] = [
            "sourcePath": memosDir.appendingPathComponent("already-imported.m4a").path
        ]
        let metaData = try JSONSerialization.data(withJSONObject: meta)
        try metaData.write(to: recordingsDir.appendingPathComponent("Wimm_2026-01-01_10-00-00.meta.json"))

        let importer = makeImporter()
        await importer.backfillFromExistingMetadataIfNeeded()
        let scan = await importer.pendingFiles()

        XCTAssertEqual(scan.pending.map(\.lastPathComponent), ["new.m4a"])
    }

    func testBackfillRunsOnlyOnce() async throws {
        let importer = makeImporter()
        await importer.backfillFromExistingMetadataIfNeeded()

        // A meta file appearing later must not be re-scanned by a new instance.
        let old = Date().addingTimeInterval(-3600)
        try writeMemo("late.m4a", modified: old)
        let meta: [String: Any] = [
            "sourcePath": memosDir.appendingPathComponent("late.m4a").path
        ]
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: recordingsDir.appendingPathComponent("Wimm_2026-01-02_10-00-00.meta.json"))

        let second = makeImporter()
        await second.backfillFromExistingMetadataIfNeeded()
        let scan = await second.pendingFiles()

        XCTAssertEqual(scan.pending.map(\.lastPathComponent), ["late.m4a"])
    }

    func testMissingFolderYieldsEmptyScan() async {
        let importer = VoiceMemosAutoImporter(folder: nil, stateURL: stateURL, recordingsDirectory: recordingsDir)
        let scan = await importer.pendingFiles()
        XCTAssertTrue(scan.pending.isEmpty)
        XCTAssertFalse(scan.accessDenied)
    }
}
