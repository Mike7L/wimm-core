import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class RecordingBundleSnapshotTests: XCTestCase {
    private var base: URL!
    private var recordings: URL { FileStore.recordingsDirectory() }
    private var previousBase: String?
    private let builder = RecordingBundleBuilder(originDeviceId: "snapshot-test")

    override func setUpWithError() throws {
        previousBase = ProcessInfo.processInfo.environment["WIMM_BASE_DIR"]
        base = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-snapshot-\(UUID().uuidString)")
        setenv("WIMM_BASE_DIR", base.path, 1)
        try FileStore.ensureDirectoryExists()
    }

    override func tearDownWithError() throws {
        if let previousBase { setenv("WIMM_BASE_DIR", previousBase, 1) } else { unsetenv("WIMM_BASE_DIR") }
        try FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func touch(_ name: String) throws -> URL {
        let url = recordings.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func identify(_ recording: URL) throws {
        try RecordingSyncMetadata.ensureSyncID(for: recording)
    }

    /// Pre-optimization discovery, retained here as an independent equivalence oracle.
    /// Only directory listings are counted; metadata reads/stats remain real filesystem I/O.
    private func legacyFiles(for recording: URL, listings: inout Int) throws -> [RecordingBundleFile] {
        var seen = Set<String>()
        var members: [(URL, RecordingBundleFileRole)] = []
        func append(_ url: URL, _ role: RecordingBundleFileRole) {
            let resolved = url.resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: resolved.path), seen.insert(resolved.path).inserted {
                members.append((resolved, role))
            }
        }
        append(recording, .primary)
        let meta = FileStore.metadataURL(forRecordingURL: recording)
        append(meta, .metadata)
        append(FileStore.legacyPNGScreenshotURL(forRecordingURL: recording), .screenshot)
        let main = FileStore.screenshotURL(forRecordingURL: recording)
        let screen = recording.deletingPathExtension().lastPathComponent + "_screen1.heic"
        if !FileManager.default.fileExists(atPath: main.path),
           !FileManager.default.fileExists(atPath: recording.deletingLastPathComponent().appendingPathComponent(screen).path) {
            listings += 1
        }
        for url in FileStore.allScreenshotURLs(forRecordingURL: recording) { append(url, .screenshot) }
        if let data = try? Data(contentsOf: meta),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let attachments = json["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                guard let raw = attachment["url"] as? String else { continue }
                let url = raw.contains("://") ? URL(string: raw) : nil
                append(url?.isFileURL == true ? url! : FileStore.resolveRelativePath(raw), .attachment)
            }
        }
        listings += 1
        let prefix = recording.deletingPathExtension().lastPathComponent + "_Attach_"
        for url in try FileManager.default.contentsOfDirectory(at: recording.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(prefix) {
            append(url, .attachment)
        }
        return try members.map { url, role in
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return RecordingBundleFile(role: role, relativePath: FileStore.relativePath(for: url), fileName: url.lastPathComponent,
                                       byteSize: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                                       modifiedAt: attrs[.modificationDate] as? Date ?? Date())
        }
    }

    func testBundleMembersAndManifestMatchLegacyDiscovery() throws {
        let names = ["audio.m4a", "document.pdf", "standalone.heic", "standalone-png.png", "fallback.txt", "screens.txt", "legacy.txt"]
        let primaries = try names.map { try touch($0) }
        try touch("audio.heic")
        try touch("audio.png")
        try touch("audio_screen1.heic")
        try touch("audio_screen2.heic")
        try touch("audio_screen4.heic") // the gap at 3 still ends the screen sequence
        try touch("audio_micro.m4a")
        try touch("audio_mini.m4a")
        try touch("orphan_micro.m4a")
        try touch("document.heic")
        try touch("fallback_Attach_screenshot_B.HEIC")
        try touch("fallback_Attach_screenshot_A.heic")
        try touch("screens_screen1.heic")
        try touch("screens_Attach_screenshot_A.heic")
        let attachment = try touch("audio_Attach_clip.txt")
        try touch("audio_Attach_no-metadata.bin")
        let nested = base.appendingPathComponent("Attachments/Evernote/id/file.pdf")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pdf".utf8).write(to: nested)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: primaries[0])) { json in
            json["attachments"] = [["url": attachment.absoluteString], ["url": FileStore.relativePath(for: nested)], ["url": "missing.pdf"]]
            return true
        }
        // Preserve legacy .metadata.json selection as well.
        try FileStore.mutateSidecar(at: recordings.appendingPathComponent("legacy.metadata.json")) { $0["title"] = "legacy"; return true }
        for primary in primaries { try identify(primary) }
        let snapshot = RecordingBundleDirectorySnapshot()
        var legacyListings = 0
        for primary in primaries {
            let bundle = try builder.build(for: primary, assignSyncID: false, directorySnapshot: snapshot)
            let expected = try legacyFiles(for: primary, listings: &legacyListings)
            XCTAssertEqual(Set(bundle.manifest.files), Set(expected), primary.lastPathComponent)
            XCTAssertEqual(bundle.manifest.updatedAt, expected.map(\.modifiedAt).max())
            XCTAssertEqual(bundle.manifest.syncId, RecordingSyncMetadata.readSyncID(for: primary))
            XCTAssertEqual(bundle.manifest.schemaVersion, 1)
            XCTAssertEqual(bundle.manifest.filenamePrefix, primary.deletingPathExtension().lastPathComponent)
            XCTAssertEqual(bundle.manifest.originDeviceId, "snapshot-test")
            let inspected = builder.inspect(for: primary, directorySnapshot: snapshot)
            XCTAssertNil(inspected.error)
            XCTAssertEqual(inspected.fileCount, expected.count)
            XCTAssertEqual(inspected.totalBytes, expected.reduce(UInt64(0)) { $0 + $1.byteSize })
        }
        XCTAssertEqual(snapshot.directoryEnumerationCount, 1)
        XCTAssertThrowsError(try builder.build(for: recordings.appendingPathComponent("orphan_micro.m4a"), assignSyncID: true))
    }

    func testBrokenMainScreenshotSymlinkStillUsesAttachFallback() throws {
        let primary = try touch("broken.txt")
        try identify(primary)
        try FileManager.default.createSymbolicLink(atPath: recordings.appendingPathComponent("broken.heic").path,
                                                  withDestinationPath: recordings.appendingPathComponent("missing.heic").path)
        let attachment = try touch("broken_Attach_screenshot_A.heic")
        let bundle = try builder.build(for: primary, assignSyncID: false)
        XCTAssertTrue(bundle.files.contains { $0.url == attachment && $0.descriptor.role == .screenshot })
        var count = 0
        XCTAssertEqual(Set(bundle.manifest.files), Set(try legacyFiles(for: primary, listings: &count)))
    }

    func testRefreshesAfterAddRemoveRenameAndSidecarChanges() throws {
        let primary = try touch("live.txt")
        try identify(primary)
        let snapshot = RecordingBundleDirectorySnapshot()
        let initial = try builder.build(for: primary, assignSyncID: true, directorySnapshot: snapshot)
        let sidecar = FileStore.metadataURL(forRecordingURL: primary)
        let sidecarData = try Data(contentsOf: sidecar)
        _ = try builder.build(for: primary, assignSyncID: true, directorySnapshot: snapshot)
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarData) // no sync timestamp rewrite
        XCTAssertEqual(snapshot.directoryEnumerationCount, 1)
        let newAttachment = try touch("live_Attach_new.txt")
        let newScreen = try touch("live_screen1.heic")
        let added = try builder.build(for: primary, assignSyncID: true, directorySnapshot: snapshot)
        XCTAssertEqual(added.files.count, initial.files.count + 2)
        XCTAssertTrue(added.files.contains { $0.url == newAttachment })
        XCTAssertTrue(added.files.contains { $0.url == newScreen && $0.descriptor.role == .screenshot })
        try FileManager.default.removeItem(at: newAttachment)
        let renamed = recordings.appendingPathComponent("live_Attach_renamed.heic")
        try FileManager.default.moveItem(at: newScreen, to: renamed)
        let changed = try builder.build(for: primary, assignSyncID: false, directorySnapshot: snapshot)
        XCTAssertFalse(changed.files.contains { $0.url == newAttachment || $0.url == newScreen })
        XCTAssertTrue(changed.files.contains { $0.url == renamed && $0.descriptor.role == .attachment })
        let external = base.appendingPathComponent("external.txt")
        try Data("new external attachment".utf8).write(to: external)
        try FileStore.mutateSidecar(at: sidecar) { $0["attachments"] = [["url": external.absoluteString]]; return true }
        let edited = try builder.build(for: primary, assignSyncID: false, directorySnapshot: snapshot)
        XCTAssertTrue(edited.files.contains { $0.url == external })
        XCTAssertEqual(snapshot.directoryEnumerationCount, 4)
    }

    func testMutationDuringCollectionRetriesAndContinuousChurnFails() throws {
        let snapshot = RecordingBundleDirectorySnapshot()
        var attempts = 0
        let names: Set<String> = try snapshot.withCurrentIndex(in: recordings) { index in
            attempts += 1
            if attempts == 1 { try touch("arrived_Attach_file.txt") }
            return Set((index.fileURLs(in: recordings) ?? []).map(\.lastPathComponent))
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(names.contains("arrived_Attach_file.txt"))
        XCTAssertEqual(snapshot.directoryEnumerationCount, 2)
        XCTAssertThrowsError(try snapshot.withCurrentIndex(in: recordings) { _ in
            try touch("churn-\(UUID().uuidString).txt")
        })
    }

    func testBackfillKeepsPrimaryAnchorsAndQueuesPreparedBatch() async throws {
        for name in ["document.pdf", "document.heic", "standalone.heic", "audio.m4a", "audio_micro.m4a", "orphan_mini.m4a", "audio_Attach_clip.txt"] { try touch(name) }
        let state = SyncStateStore(stateURL: base.appendingPathComponent("ledger.json"))
        let service = RecordingSyncBackfillService(builder: builder, stateStore: state)
        let snapshot = RecordingBundleDirectorySnapshot()
        let result = await service.run(options: RecordingSyncBackfillOptions(dryRun: false), directorySnapshot: snapshot)
        XCTAssertEqual(snapshot.directoryEnumerationCount, 2) // candidates, then the prepared batch
        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.enqueued, 3)
        XCTAssertEqual(result.failed, 0)
        let queued = await state.entries(with: [.pendingUpload])
        XCTAssertEqual(Set(queued.map { FileStore.resolveRelativePath($0.localRelativePath).lastPathComponent }), ["document.pdf", "standalone.heic", "audio.m4a"])
    }

    func testBackfillSinceAndLimitUseCachedFileDatesInAscendingOrder() async throws {
        let old = try touch("old.txt")
        let first = try touch("first.txt")
        let last = try touch("last.txt")
        for (url, stamp) in [(old, 100.0), (first, 200.0), (last, 300.0)] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: stamp)], ofItemAtPath: url.path)
        }
        let state = SyncStateStore(stateURL: base.appendingPathComponent("ledger.json"))
        let service = RecordingSyncBackfillService(builder: builder, stateStore: state)
        let result = await service.run(options: RecordingSyncBackfillOptions(dryRun: false, limit: 1, since: Date(timeIntervalSince1970: 150)))
        XCTAssertEqual(result.scanned, 2)
        XCTAssertEqual(result.enqueued, 1)
        let queued = await state.entries(with: [.pendingUpload])
        XCTAssertEqual(queued.map { FileStore.resolveRelativePath($0.localRelativePath).lastPathComponent }, ["first.txt"])
        XCTAssertNil(RecordingSyncMetadata.readSyncID(for: old))
        XCTAssertNil(RecordingSyncMetadata.readSyncID(for: last))
    }

    /// Opt-in wall-clock probe on an isolated 15,399-file catalog, never the library.
    func testRepresentativeBatchBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WIMM_SYNC_BUNDLE_BENCHMARK"] == "1")
        var primaries: [URL] = []
        for i in 0..<200 {
            let primary = try touch(String(format: "Wimm_2026-05-31_10-00-00_%03d.txt", i))
            try touch(primary.deletingPathExtension().lastPathComponent + "_Attach_clip.txt")
            try identify(primary)
            primaries.append(primary)
        }
        for i in 600..<15_399 { try touch(String(format: "Wimm_2025-01-01_12-00-00_filler_%05d.m4a", i)) }
        var oldTimes: [Double] = [], newTimes: [Double] = []
        for _ in 0..<3 {
            var oldCount = 0
            var expected: [Set<RecordingBundleFile>] = []
            var start = Date()
            for url in primaries {
                expected.append(try autoreleasepool { Set(try legacyFiles(for: url, listings: &oldCount)) })
            }
            oldTimes.append(Date().timeIntervalSince(start))
            let snapshot = RecordingBundleDirectorySnapshot()
            start = Date()
            for (i, url) in primaries.enumerated() {
                let bundle = try autoreleasepool { try builder.build(for: url, assignSyncID: true, directorySnapshot: snapshot) }
                XCTAssertEqual(Set(bundle.manifest.files), expected[i])
            }
            newTimes.append(Date().timeIntervalSince(start))
            XCTAssertEqual(oldCount, 400)
            XCTAssertEqual(snapshot.directoryEnumerationCount, 1)
        }
        print("SYNC_BUNDLE_BENCHMARK files=15399 batch=200 legacy_discovery_seconds=\(oldTimes) indexed_build_seconds=\(newTimes) listings=400->1")
    }
}
