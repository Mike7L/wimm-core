import Foundation
import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class SecretaryRecallCacheTests: XCTestCase {
    private var root: URL!
    private var previousBase: String?
    private var cache: URL { root.appendingPathComponent("cache") }
    private var recordings: URL { root.appendingPathComponent("Recordings") }
    override func setUpWithError() throws {
        previousBase = ProcessInfo.processInfo.environment["WIMM_BASE_DIR"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("secretary-cache-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", root.path, 1)
        for i in 0..<2 {
            let file = recordings.appendingPathComponent("Wimm_2026-10-30_12-00-0\(i).txt")
            try "Body \(i): Ёж 🦔".write(to: file, atomically: true, encoding: .utf8)
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { $0["recordingId"] = UUID().uuidString; return true }
        }
    }
    override func tearDown() {
        if let previousBase { setenv("WIMM_BASE_DIR", previousBase, 1) } else { unsetenv("WIMM_BASE_DIR") }
        try? FileManager.default.removeItem(at: root)
    }
    private func loader() -> LibraryRecallSource { LibraryRecallSource(includeFingerprints: true, cacheDirectory: cache) }

    func testCrossProcessSnapshotReusesUnchangedNotesAndDetectsPreservedMtimeEdits() async throws {
        let first = loader(), a = await first.load()
        XCTAssertEqual(a.count, 2)
        let builtFirst = await first.rebuiltNoteCount; XCTAssertEqual(builtFirst, 2)
        let second = loader(), b = await second.load()
        let restored = await second.restoredFromDisk, rebuilt = await second.rebuiltNoteCount
        XCTAssertTrue(restored); XCTAssertEqual(rebuilt, 0)
        XCTAssertEqual((0..<a.count).map { a[$0] }, (0..<b.count).map { b[$0] })
        let file = URL(fileURLWithPath: a[0].filePath)
        let old = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as! Date
        try "A real edit with the same mtime".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let third = loader(), c = await third.load()
        let rebuiltThird = await third.rebuiltNoteCount
        XCTAssertEqual(rebuiltThird, 1)
        XCTAssertTrue((0..<c.count).contains { c[$0].text.contains("real edit") })
        try FileManager.default.removeItem(at: URL(fileURLWithPath: a[1].filePath))
        let fourth = loader(), d = await fourth.load()
        XCTAssertEqual(d.count, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent(LibraryRecallSource.cacheFileName).path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testTruncatedCacheRebuildsFromCanonicalFiles() async throws {
        _ = await loader().load()
        try Data("corrupt\ncache".utf8).write(to: cache.appendingPathComponent(LibraryRecallSource.cacheFileName))
        let next = loader(), result = await next.load()
        let restored = await next.restoredFromDisk, rebuilt = await next.rebuiltNoteCount
        XCTAssertEqual(result.count, 2); XCTAssertFalse(restored); XCTAssertEqual(rebuilt, 2)
    }

    func testMalformedPathRangesRebuildWithoutReadingInvalidMemory() async throws {
        _ = await loader().load()
        let file = cache.appendingPathComponent(LibraryRecallSource.cacheFileName)
        var modified = try Data(contentsOf: file)
        // Body: path bytes (length + bytes), file count, then the first file's range.
        let body = try XCTUnwrap(modified.firstIndex(of: 10)) + 1
        let pathBytes = modified[body..<body + 8].withUnsafeBytes { Int($0.loadUnaligned(as: UInt64.self).littleEndian) }
        let upper = body + 8 + pathBytes + 8 + 8
        withUnsafeBytes(of: UInt64(Int64.max).littleEndian) { modified.replaceSubrange(upper..<upper + 8, with: $0) }
        try modified.write(to: file)
        let next = loader(), result = await next.load()
        let restored = await next.restoredFromDisk, rebuilt = await next.rebuiltNoteCount
        XCTAssertEqual(result.count, 2); XCTAssertFalse(restored); XCTAssertEqual(rebuilt, 2)
    }

    func testTruncatedRecordRebuildsFromCanonicalFiles() async throws {
        _ = await loader().load()
        let file = cache.appendingPathComponent(LibraryRecallSource.cacheFileName)
        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count - 3).write(to: file)
        let next = loader(), result = await next.load()
        let restored = await next.restoredFromDisk, rebuilt = await next.rebuiltNoteCount
        XCTAssertEqual(result.count, 2); XCTAssertFalse(restored); XCTAssertEqual(rebuilt, 2)
    }

    func testRestoredCacheSeesAddedNoteWithoutChangingOthers() async throws {
        let first = await loader().load()
        let file = recordings.appendingPathComponent("Wimm_2026-10-30_12-00-05.txt")
        try "Body new: маяк".write(to: file, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { $0["recordingId"] = UUID().uuidString; return true }
        let next = loader(), result = await next.load()
        let restored = await next.restoredFromDisk, rebuilt = await next.rebuiltNoteCount
        XCTAssertTrue(restored); XCTAssertEqual(rebuilt, 1); XCTAssertEqual(result.count, 3)
        XCTAssertEqual(Set((0..<first.count).map { first[$0].filePath }).subtracting((0..<result.count).map { result[$0].filePath }), [])
    }

    func testCacheCannotBeReusedAcrossLibraryRoots() async throws {
        _ = await loader().load()
        let alternate = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: alternate.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", alternate.path, 1)
        let other = loader(), result = await other.load()
        let restored = await other.restoredFromDisk
        XCTAssertEqual(result.count, 0); XCTAssertFalse(restored)
    }
}
