import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class StudioLibraryTests: XCTestCase {
    @MainActor func testIncrementalUpdatesDeletionAndBoundedProjection() async throws {
        let root = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prefix = "StudioFixture_" + UUID().uuidString
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: file)) } }
        for i in 0..<5 {
            let file = root.appendingPathComponent("\(prefix)_\(i).txt")
            files.append(file)
            try String(repeating: "large text ", count: 10000).write(to: file, atomically: true, encoding: .utf8)
            FileStore.upsertMetadata(for: file, updates: ["manualTitle": "Old manual title", "noteCard": ["schema": Schemas.noteCard, "note_file": file.lastPathComponent, "title": "Title \(i)", "summary": "Summary \(i)"]])
        }
        let metadata = MetadataRepository()
        let store = StudioLibraryStore(limit: 2, metadata: metadata)
        let first = await store.update(changedFiles: Set(files))
        XCTAssertEqual(first.entries.count, 5)
        XCTAssertEqual(first.recent.count, 2)
        XCTAssertEqual(first.decoded, 5)
        let initialReads = await metadata.sidecarReadCount
        XCTAssertEqual(initialReads, 5)
        XCTAssertTrue(first.recent.allSatisfy { $0.metadataSearchText.isEmpty })
        XCTAssertTrue(first.entries.allSatisfy { $0.studioTitle.hasPrefix("large text ") && $0.studioTitle.hasSuffix("…") })
        XCTAssertTrue(first.entries.allSatisfy { $0.minutes > 1 })
        let unchanged = await store.update(changedFiles: Set(files))
        XCTAssertEqual(unchanged.decoded, 0)
        let unchangedReads = await metadata.sidecarReadCount
        XCTAssertEqual(unchangedReads, initialReads)
        try "Changed text".write(to: files[0], atomically: true, encoding: .utf8)
        let changed = await store.update(changedFiles: [files[0]])
        XCTAssertEqual(changed.decoded, 1)
        let changedReads = await metadata.sidecarReadCount
        XCTAssertEqual(changedReads - unchangedReads, 1)
        XCTAssertEqual(changed.entries.first(where: { $0.fileURL == files[0] })?.studioTitle, "Changed text")
        let victim = try XCTUnwrap(changed.recent.last?.fileURL)
        try FileManager.default.removeItem(at: victim)
        let deleted = await store.update(changedFiles: [victim])
        XCTAssertEqual(deleted.entries.count, 4)
        XCTAssertEqual(deleted.recent.count, 2)
        XCTAssertFalse(deleted.entries.contains { $0.fileURL == victim })
    }

    @MainActor func testReloadsCoalesceAndLaterChangesUpdate() async throws {
        let root = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("StudioCoalesce_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try "one".write(to: file, atomically: true, encoding: .utf8)
        let recent = RecentNotes(limit: 1)
        for _ in 0..<20 { recent.reload(changedFiles: [file]) }
        await recent.waitUntilLoaded()
        XCTAssertFalse(recent.isLoading)
        XCTAssertEqual(recent.allNotes.count, 1)
        XCTAssertEqual(recent.revision, 1)
        try "two".write(to: file, atomically: true, encoding: .utf8)
        recent.reload(changedFiles: [file])
        await recent.waitUntilLoaded()
        XCTAssertEqual(recent.notes.first?.text, "two")
        XCTAssertEqual(recent.lastDecodedCount, 1)
    }
}
