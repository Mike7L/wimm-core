import XCTest
@testable import WimmDomain

/// A `.meta.json` sidecar is written by several subsystems — the recorder,
/// `NoteOrigin`, CloudSync, transcription, the trash, `RecordingMetadata` —
/// often within the same second of one recording. These tests pin the two
/// properties that sharing depends on.
final class SidecarWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }

    override func tearDown() {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func sidecar(for recording: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: recording))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private final class EventCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count == 1 }
    }
    func testUnreadableSidecarIsNeverOverwritten() throws {
        let url = tempDir.appendingPathComponent("broken.meta.json")
        let garbage = Data("{\"transcription\": {\"transcript\": \"keep".utf8)
        try garbage.write(to: url)
        XCTAssertThrowsError(try FileStore.mutateSidecar(at: url) { $0["x"] = 1; return true })
        XCTAssertEqual(try Data(contentsOf: url), garbage)

        let missing = tempDir.appendingPathComponent("new.meta.json")
        try FileStore.mutateSidecar(at: missing) { $0["x"] = 1; return true }
        XCTAssertNotNil(try Data(contentsOf: missing))
    }

    func testNotificationIsDeliveredAfterUnlockAndSeesCommittedData() throws {
        let recording = tempDir.appendingPathComponent("notify.m4a")
        try Data().write(to: recording)
        let expected = FileStore.metadataURL(forRecordingURL: recording)
        let counter = EventCount()
        let observer = NotificationCenter.default.addObserver(forName: FileStore.sidecarDidChange, object: nil, queue: nil) { event in
            guard event.object as? URL == expected, counter.first() else { return }
            // This would deadlock if notification delivery still held the writer lock.
            FileStore.upsertMetadata(for: recording, updates: ["observer": true])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        FileStore.upsertMetadata(for: recording, updates: ["writer": true])
        let result = try sidecar(for: recording)
        XCTAssertEqual(result["writer"] as? Bool, true)
        XCTAssertEqual(result["observer"] as? Bool, true)
    }

    /// Writers entering through different doors must not erase each other's
    /// keys. Before every door took the shared lock, only `upsertMetadata`
    /// did — two unsynchronized read-modify-writes lose whichever lands first.
    func testConcurrentWritersThroughDifferentDoorsKeepEveryKey() throws {
        let recording = tempDir.appendingPathComponent("race.m4a")
        try Data().write(to: recording)
        let metaURL = FileStore.metadataURL(forRecordingURL: recording)
        let repo = IOSRecordingRepository()
        let writers = 60

        DispatchQueue.concurrentPerform(iterations: writers * 3) { i in
            let n = i / 3
            switch i % 3 {
            case 0:
                FileStore.upsertMetadata(for: recording, updates: ["upsert_\(n)": n])
            case 1:
                repo.upsertMetadata(file: recording, updates: ["ios_\(n)": n])
            default:
                try? FileStore.mutateSidecar(at: metaURL) { json in
                    json["direct_\(n)"] = n
                    return true
                }
            }
        }

        let json = try sidecar(for: recording)
        for n in 0..<writers {
            XCTAssertEqual(json["upsert_\(n)"] as? Int, n, "lost upsert_\(n)")
            XCTAssertEqual(json["ios_\(n)"] as? Int, n, "lost ios_\(n)")
            XCTAssertEqual(json["direct_\(n)"] as? Int, n, "lost direct_\(n)")
        }
    }

    /// `RecordingMetadata.save()` merges into the shared sidecar but writes
    /// only its own keys to the legacy `.metadata.json` copy. bf046dc turned
    /// the legacy write into a full clone of the shared sidecar by reusing a
    /// variable name.
    func testSaveMergesSharedSidecarButKeepsLegacyCopyToOwnKeys() throws {
        let recording = tempDir.appendingPathComponent("legacy.m4a")
        try Data().write(to: recording)
        FileStore.upsertMetadata(for: recording, updates: ["origin": ["platform": "iPhone"]])

        try RecordingMetadata(recordingURL: recording, transcription: "hello").save()

        let shared = try sidecar(for: recording)
        XCTAssertNotNil(shared["origin"], "save() must not drop a key another writer owns")
        XCTAssertEqual(shared["transcription"] as? String, "hello")

        let legacyData = try Data(contentsOf: RecordingMetadata.legacyMetadataURL(for: recording))
        let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(legacy["origin"], "legacy copy must hold RecordingMetadata's own keys only")
        XCTAssertEqual(legacy["transcription"] as? String, "hello")
    }

    /// A non-JSON value must surface as a thrown error. Handing it to
    /// `JSONSerialization` raises an Objective-C exception, which crashes.
    func testInvalidValueThrowsInsteadOfCrashing() throws {
        let url = tempDir.appendingPathComponent("bad.meta.json")
        XCTAssertThrowsError(try FileStore.mutateSidecar(at: url) { json in
            json["date"] = Date()
            return true
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Cross-process lock

    private final class Intervals: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Date, Date)] = []
        func add(_ start: Date, _ end: Date) { lock.lock(); items.append((start, end)); lock.unlock() }
        var all: [(Date, Date)] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func testLockFileLivesOutsideTheLibrary() {
        let sidecar = tempDir.appendingPathComponent("a.meta.json")
        let lockURL = SidecarFileLock.lockFileURL(forSidecar: sidecar)
        XCTAssertFalse(lockURL.path.hasPrefix(tempDir.resolvingSymlinksInPath().path))
        XCTAssertFalse(lockURL.path.hasPrefix(tempDir.path))
        XCTAssertFalse(FileStore.isSupportedRecordingFile(lockURL))
        // One file, two spellings of its directory: one lock.
        let viaPrivate = URL(fileURLWithPath: tempDir.resolvingSymlinksInPath().path)
            .appendingPathComponent("a.meta.json")
        XCTAssertEqual(lockURL, SidecarFileLock.lockFileURL(forSidecar: viaPrivate))
    }

    /// Each holder opens its own descriptor, as a separate process does, and
    /// skips the in-process `NSLock`; the `flock` alone must serialize them.
    func testIndependentLockHoldersOnOneSidecarSerialize() {
        let sidecar = tempDir.appendingPathComponent("shared.meta.json")
        let intervals = Intervals()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            SidecarFileLock.withLock(forSidecar: sidecar) {
                let start = Date()
                Thread.sleep(forTimeInterval: 0.1)
                intervals.add(start, Date())
            }
        }
        let sorted = intervals.all.sorted { $0.0 < $1.0 }
        XCTAssertEqual(sorted.count, 4)
        for (earlier, later) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.1, later.0, "lock holders overlapped")
        }
    }

    #if os(macOS)
    /// A real second process holds the sidecar's lock; `mutateSidecar` must
    /// wait for it instead of writing at once.
    func testMutateSidecarWaitsForAnotherProcessHoldingTheLock() throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: perl.path), "no /usr/bin/perl")
        let sidecar = tempDir.appendingPathComponent("other-process.meta.json")
        let lockURL = SidecarFileLock.lockFileURL(forSidecar: sidecar)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let holder = Process()
        holder.executableURL = perl
        holder.arguments = ["-e", #"use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "locked\n"; select(undef, undef, undef, 0.8);"#, lockURL.path]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertEqual(line, "locked\n")

        let start = Date()
        try FileStore.mutateSidecar(at: sidecar) { $0["after"] = true; return true }
        let waited = Date().timeIntervalSince(start)
        holder.waitUntilExit()
        XCTAssertGreaterThan(waited, 0.5, "wrote while another process held the lock")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual(json["after"] as? Bool, true)
    }
    #endif

    func testSwallowedMetadataFailureIsLogged() throws {
        let recording = tempDir.appendingPathComponent("corrupt.m4a")
        try Data().write(to: recording)
        let sidecarURL = FileStore.metadataURL(forRecordingURL: recording)
        let garbage = Data("{\"broken\": ".utf8)
        try garbage.write(to: sidecarURL)

        FileStore.upsertMetadata(for: recording, updates: ["x": 1])
        XCTAssertEqual(try Data(contentsOf: sidecarURL), garbage)

        let eventsDir = UnifiedEventLogger.eventsDirectoryURL()
        let deadline = Date().addingTimeInterval(5)
        var found: [String: Any]?
        while found == nil, Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(at: eventsDir, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                for line in text.split(separator: "\n") {
                    guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          event["kind"] as? String == FileStore.sidecarWriteFailedEventKind else { continue }
                    found = event
                }
            }
            if found == nil { Thread.sleep(forTimeInterval: 0.05) }
        }
        let event = try XCTUnwrap(found, "no sidecar_write_failed event in \(eventsDir.path)")
        // The logger may redact digit runs in the temp path; the file name stays.
        XCTAssertTrue((event["message"] as? String)?.hasSuffix("corrupt.meta.json") == true)
        XCTAssertNotNil(event["error"] as? String)
    }
}
