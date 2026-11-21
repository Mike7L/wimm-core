import CryptoKit
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

    func testListingFingerprintSurvivesTheJSONHeaderForAnyHash() throws {
        // Half of all hash sums exceed Int64.max; the header must still decode them.
        for seed in 0..<64 {
            let listing = LibraryRecallSource.DirectoryFingerprint(["/a/\(seed)": Date(timeIntervalSince1970: Double(seed))])
            let decoded = try JSONDecoder().decode(LibraryRecallSource.DirectoryFingerprint.self, from: JSONEncoder().encode(listing))
            XCTAssertEqual(decoded, listing)
        }
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

    func testCacheWrittenByOneExecutableIsRestoredByAnother() async throws {
        _ = await loader().load()
        // Another installed CLI of the same version: a different path, size and date.
        let other = LibraryRecallSource(
            buildMode: .subprocess(executable: root.appendingPathComponent("elsewhere/WimmCLI"), arguments: []),
            includeFingerprints: true, cacheDirectory: cache)
        let result = await other.load()
        let restored = await other.restoredFromDisk, rebuilt = await other.rebuiltNoteCount
        XCTAssertEqual(result.count, 2); XCTAssertTrue(restored); XCTAssertEqual(rebuilt, 0)
    }

    func testCacheOfAnotherBuilderVersionIsRebuiltAndReplaced() async throws {
        _ = await loader().load()
        func newer() -> LibraryRecallSource {
            LibraryRecallSource(buildMode: .inProcess, includeFingerprints: true, cacheDirectory: cache,
                                builderVersion: LibraryRecallSource.cacheBuilderVersion + 1)
        }
        let next = newer(), result = await next.load()
        let restored = await next.restoredFromDisk, rebuilt = await next.rebuiltNoteCount
        XCTAssertEqual(result.count, 2); XCTAssertFalse(restored); XCTAssertEqual(rebuilt, 2)
        let again = newer(); _ = await again.load()
        let restoredAgain = await again.restoredFromDisk
        XCTAssertTrue(restoredAgain)
        let old = loader(); _ = await old.load()
        let restoredOld = await old.restoredFromDisk
        XCTAssertFalse(restoredOld)
    }

    func testCacheOfAnotherFormatVersionIsRebuilt() async throws {
        _ = await loader().load()
        let file = cache.appendingPathComponent(LibraryRecallSource.cacheFileName)
        let bytes = try Data(contentsOf: file)
        let newline = try XCTUnwrap(bytes.firstIndex(of: 10))
        var header = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes.prefix(upTo: newline)) as? [String: Any])
        XCTAssertEqual(header["version"] as? Int, LibraryRecallSource.cacheVersion)
        XCTAssertNil(header["producer"])
        header["version"] = LibraryRecallSource.cacheVersion + 1
        var changed = try JSONSerialization.data(withJSONObject: header)
        changed.append(bytes.suffix(from: newline))
        try changed.write(to: file)
        let next = loader(), result = await next.load()
        let restored = await next.restoredFromDisk, rebuilt = await next.rebuiltNoteCount
        XCTAssertEqual(result.count, 2); XCTAssertFalse(restored); XCTAssertEqual(rebuilt, 2)
    }

    func testSavingRemovesSupersededCacheFiles() async throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for name in ["recall-v1.stream", "recall-v2.stream"] { try Data("old".utf8).write(to: cache.appendingPathComponent(name)) }
        _ = await loader().load()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [LibraryRecallSource.cacheFileName])
    }

    /// The cache outlives a rebuild, so nothing else notices a build that turns
    /// the same files into different notes. When this fails because the change
    /// was intended: raise `LibraryRecallSource.cacheBuilderVersion`, then put
    /// the new number and hash here.
    func testBuiltFormOfAFixtureLibraryIsPinnedToTheBuilderVersion() async throws {
        let audio = recordings.appendingPathComponent("Wimm_2026-10-30_12-00-07.m4a")
        try Data([0, 1, 2, 3]).write(to: audio)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: audio)) {
            $0["recordingId"] = "00000000-0000-0000-0000-000000000007"
            $0["duration"] = 12.5
            $0["device"] = "macOS"
            $0["title"] = "Маяк"
            $0["summary"] = "Разговор о маяке."
            $0["transcription"] = ["transcript": "Привет, Маяк! Second line.", "provider": "parakeet",
                                   "localTranscript": "привет маяк", "model": "parakeet:ultra"] as [String: Any]
            return true
        }
        let note = recordings.appendingPathComponent("Wimm_2026-10-30_12-00-08.md")
        try "# Заголовок\n\nТекст с [[ссылкой]] и ÉCLAIR.".write(to: note, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) {
            $0["recordingId"] = "00000000-0000-0000-0000-000000000008"; return true
        }
        // The note id follows the file's path, which is a new temporary directory each run.
        let library = await loader().load()
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = []
        for i in 0..<library.count {
            let n = library[i]
            guard n.filePath.hasSuffix("-07.m4a") || n.filePath.hasSuffix("-08.md") else { continue }
            let folded = n.folded()
            let fingerprint = n.fingerprintSnapshot?.fingerprint
            lines.append([
                URL(fileURLWithPath: n.filePath).lastPathComponent, day.string(from: n.date), n.kind,
                n.title ?? "-", n.summary ?? "-", n.text,
                n.duration.map { "\($0)" } ?? "-", n.speech ?? "-", n.chars.map { "\($0)" } ?? "-", n.device ?? "-",
                folded.title, folded.summary, folded.body,
                fingerprint?.text ?? "-", fingerprint?.analysis ?? "-", fingerprint?.wording ?? "-",
            ].joined(separator: "\u{1E}"))
        }
        XCTAssertEqual(lines.count, 2)
        let built = lines.sorted().joined(separator: "\n")
        let hash = SHA256.hash(data: Data(built.utf8)).map { String(format: "%02x", $0) }.joined()
        let pinned = (builder: 2, hash: "66a99de1e28045032f3717eabdfae3aa47d3b6cb21b87cb03e2722dbeaa30eb6")
        XCTAssertEqual(LibraryRecallSource.cacheBuilderVersion, pinned.builder)
        XCTAssertEqual(hash, pinned.hash, "Built notes changed; raise cacheBuilderVersion and pin the new form:\n\(built)")
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
