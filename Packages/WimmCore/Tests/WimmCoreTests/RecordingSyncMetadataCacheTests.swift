import XCTest
@testable import WimmInfrastructure
import WimmDomain

final class RecordingSyncMetadataCacheTests: XCTestCase {
    func testReadSyncIDFollowsSidecarRewrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = dir.appendingPathComponent("Wimm_2026-11-11_10-00-00_AAAAAAAA.m4a")
        try Data().write(to: note)
        let sidecar = FileStore.metadataURL(forRecordingURL: note)

        XCTAssertNil(RecordingSyncMetadata.readSyncID(for: note))

        try Data(#"{"syncId":"first"}"#.utf8).write(to: sidecar, options: .atomic)
        XCTAssertEqual(RecordingSyncMetadata.readSyncID(for: note)?.rawValue, "first")
        XCTAssertEqual(RecordingSyncMetadata.readSyncID(for: note)?.rawValue, "first")

        // Same length, rewritten in place and atomically: the cached answer must not survive.
        try Data(#"{"syncId":"other"}"#.utf8).write(to: sidecar, options: .atomic)
        XCTAssertEqual(RecordingSyncMetadata.readSyncID(for: note)?.rawValue, "other")
        let handle = try FileHandle(forWritingTo: sidecar)
        try handle.write(contentsOf: Data(#"{"syncId":"third"}"#.utf8))
        try handle.close()
        XCTAssertEqual(RecordingSyncMetadata.readSyncID(for: note)?.rawValue, "third")

        try Data(#"{"note":"no id"}"#.utf8).write(to: sidecar, options: .atomic)
        XCTAssertNil(RecordingSyncMetadata.readSyncID(for: note))
        try FileManager.default.removeItem(at: sidecar)
        XCTAssertNil(RecordingSyncMetadata.readSyncID(for: note))
    }
}
