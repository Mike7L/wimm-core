import XCTest
import WimmDomain
import WimmInfrastructure
import WimmTestSupport

/// `validateAll(fix:)` used to write back the sidecar dictionary it read at
/// the top of each iteration, bypassing the sidecar lock. It now re-applies
/// its repairs to a fresh read inside `FileStore.mutateSidecar`.
final class MetadataAuditServiceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }

    override func tearDown() {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func sidecar(_ recording: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: recording))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFixRepairsLegacyShapesAndKeepsOtherKeys() async throws {
        let recording = tempDir.appendingPathComponent("Wimm_2026-10-05_10-00-00_AAAAAAAA.m4a")
        try Data().write(to: recording)
        FileStore.upsertMetadata(for: recording, updates: ["origin": ["platform": "macOS"]])
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: recording)) { json in
            json["transcription"] = "legacy text"   // the pre-object shape
            json["duration"] = 12                    // a redundant key
            return true
        }

        let missing = tempDir.appendingPathComponent("Wimm_2026-10-05_11-00-00_BBBBBBBB.m4a")
        try Data().write(to: missing)

        let repo = MockFileRepository()
        await repo.setRecordings([recording, missing])
        let report = await MetadataAuditService(fileRepository: repo).validateAll(fix: true)

        let fixed = try sidecar(recording)
        XCTAssertEqual((fixed["transcription"] as? [String: Any])?["transcript"] as? String, "legacy text")
        XCTAssertNil(fixed["duration"])
        XCTAssertNotNil(fixed["origin"], "repair must not drop keys other writers own")
        XCTAssertNoThrow(try sidecar(missing), "missing sidecar is created")
        XCTAssertEqual(report.fixed, 2)
    }
}
