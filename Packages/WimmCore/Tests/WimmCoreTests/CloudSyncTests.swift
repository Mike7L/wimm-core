import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class CloudSyncTests: XCTestCase {
    private func makeEnvIsolatedBase() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-sync-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tmp.path, 1)
        try FileStore.ensureDirectoryExists()
        return tmp
    }

    private func tearDownBase(_ base: URL) {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    func testRecordingBundleBuilderCollectsPrimaryMetadataAndAttachments() throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let recordingsDir = FileStore.recordingsDirectory()
        let recording = recordingsDir.appendingPathComponent("Wimm_2026-05-31_10-00-00.m4a")
        let attachment = recordingsDir.appendingPathComponent("Wimm_2026-05-31_10-00-00_Attach_clip.txt")
        try Data("audio".utf8).write(to: recording)
        try Data("clip".utf8).write(to: attachment)
        let metadata: [String: Any] = [
            "attachments": [[
                "id": UUID().uuidString,
                "url": attachment.absoluteString,
                "type": "text",
            ]],
        ]
        let metaData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
        try metaData.write(to: FileStore.metadataURL(forRecordingURL: recording))

        let bundle = try RecordingBundleBuilder(originDeviceId: "test-device")
            .build(for: recording, assignSyncID: true)

        XCTAssertEqual(bundle.manifest.originDeviceId, "test-device")
        XCTAssertEqual(Set(bundle.files.map { $0.descriptor.role }), [.primary, .metadata, .attachment])
        XCTAssertEqual(bundle.manifest.files.count, 3)
        XCTAssertNotNil(RecordingSyncMetadata.readSyncID(for: recording))
    }

    func testEnsureSyncIdIsStable() throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let recording = FileStore.recordingsDirectory().appendingPathComponent("stable.m4a")
        try Data("audio".utf8).write(to: recording)

        let first = try RecordingSyncMetadata.ensureSyncID(for: recording)
        let second = try RecordingSyncMetadata.ensureSyncID(for: recording)

        XCTAssertEqual(first, second)
    }

    func testSyncStateStoreRestoresQueueAfterRestart() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let stateURL = base.appendingPathComponent("sync-state.json")
        let recording = FileStore.recordingsDirectory().appendingPathComponent("queued.m4a")
        try Data("audio".utf8).write(to: recording)
        let syncId = try RecordingSyncMetadata.ensureSyncID(for: recording)

        let firstStore = SyncStateStore(stateURL: stateURL)
        try await firstStore.enqueueUpload(syncId: syncId, localURL: recording)

        let secondStore = SyncStateStore(stateURL: stateURL)
        let pending = await secondStore.entries(with: [.pendingUpload])

        XCTAssertEqual(pending.map(\.syncId), [syncId])
    }

    func testTombstoneMovesSyncedRecordingToTrash() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let recording = FileStore.recordingsDirectory().appendingPathComponent("delete-me.m4a")
        try Data("audio".utf8).write(to: recording)
        let syncId = try RecordingSyncMetadata.ensureSyncID(for: recording)
        let stateStore = SyncStateStore(stateURL: base.appendingPathComponent("state.json"))
        try await stateStore.enqueueUpload(syncId: syncId, localURL: recording)

        let deletedManifest = RecordingBundleManifest(
            syncId: syncId,
            filenamePrefix: "delete-me",
            createdAt: Date(),
            updatedAt: Date().addingTimeInterval(5),
            originDeviceId: "remote",
            files: [],
            isDeleted: true
        )
        let transport = FakeCloudTransport(remote: [RemoteRecordingBundle(manifest: deletedManifest, files: [])])
        let service = CloudRecordingSyncService(stateStore: stateStore, transport: transport)

        try await service.downloadRemoteChanges()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.path))
        let trashed = FileStore.trashDirectory().appendingPathComponent(recording.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: trashed))) as? [String: Any])
        XCTAssertEqual(meta["trashed"] as? Bool, true, "a synced delete carries the same trash marker as a local one")
        XCTAssertNotNil(meta["trashedAt"])
    }

    private func makeRemoteBundle(name: String, updatedAt: Date, content: String = "remote") -> RemoteRecordingBundle {
        let descriptor = RecordingBundleFile(
            role: .primary,
            relativePath: "Recordings/\(name).m4a",
            fileName: "\(name).m4a",
            byteSize: UInt64(content.utf8.count),
            modifiedAt: updatedAt
        )
        let manifest = RecordingBundleManifest(
            syncId: SyncRecordingID(),
            filenamePrefix: name,
            createdAt: updatedAt,
            updatedAt: updatedAt,
            originDeviceId: "iphone",
            files: [descriptor]
        )
        return RemoteRecordingBundle(
            manifest: manifest,
            files: [RemoteRecordingBundleFile(descriptor: descriptor, data: Data(content.utf8))]
        )
    }

    /// The iPhone stamps a bundle with its file time, then uploads it whenever
    /// it gets to it. A Mac sync that ran in between must not hide that note.
    func testNoteUploadedAfterLastSyncButStampedBeforeItIsDownloaded() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let lastSync = Date()
        let stateURL = base.appendingPathComponent("state.json")
        let seeded = SyncStateStore(stateURL: stateURL)
        try await seeded.updateLastSyncAt(lastSync)

        let late = makeRemoteBundle(name: "Wimm_late_upload", updatedAt: lastSync.addingTimeInterval(-600))
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: stateURL),
            transport: FakeCloudTransport(remote: [late])
        )

        let changed = try await service.downloadRemoteChanges()

        XCTAssertTrue(changed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: FileStore.recordingsDirectory().appendingPathComponent("Wimm_late_upload.m4a").path
        ))
    }

    func testFullScanAdoptsNoteAlreadyOnDiskInsteadOfReinstallingIt() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let remote = makeRemoteBundle(name: "Wimm_known", updatedAt: Date().addingTimeInterval(-90 * 24 * 3600))
        let local = FileStore.recordingsDirectory().appendingPathComponent("Wimm_known.m4a")
        try Data("local analysis".utf8).write(to: local)
        try RecordingSyncMetadata.setSyncID(remote.manifest.syncId, for: local, now: Date())

        let transport = FakeCloudTransport(remote: [remote])
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: base.appendingPathComponent("state.json")),
            transport: transport
        )

        let changed = try await service.downloadRemoteChanges(fullScan: true)

        XCTAssertFalse(changed)
        XCTAssertTrue(transport.fetchedBundles.isEmpty)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "local analysis")
        let again = try await service.downloadRemoteChanges(fullScan: true)
        XCTAssertFalse(again)
    }

    /// CloudKit hands back milliseconds; the ledger keeps whole seconds.
    func testSubSecondCloudTimestampDoesNotRedownloadKnownNote() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let stamp = Date(timeIntervalSince1970: 1_800_000_000.4)
        let remote = makeRemoteBundle(name: "Wimm_known_ms", updatedAt: stamp)
        let stateURL = base.appendingPathComponent("state.json")
        let seeded = SyncStateStore(stateURL: stateURL)
        try await seeded.markDownloaded(
            remote.manifest.syncId,
            localURL: FileStore.recordingsDirectory().appendingPathComponent("Wimm_known_ms.m4a"),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let transport = FakeCloudTransport(remote: [remote])
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: stateURL),
            transport: transport
        )

        let changed = try await service.downloadRemoteChanges(fullScan: true)

        XCTAssertFalse(changed)
        XCTAssertTrue(transport.fetchedBundles.isEmpty)
    }

    func testRemoteUpdateKeepsLocalOnlySidecarFields() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let name = "Wimm_merge"
        let primary = RecordingBundleFile(
            role: .primary, relativePath: "Recordings/\(name).m4a", fileName: "\(name).m4a",
            byteSize: 5, modifiedAt: Date()
        )
        let metadata = RecordingBundleFile(
            role: .metadata, relativePath: "Recordings/\(name).meta.json", fileName: "\(name).meta.json",
            byteSize: 0, modifiedAt: Date()
        )
        let syncId = SyncRecordingID()
        let manifest = RecordingBundleManifest(
            syncId: syncId, filenamePrefix: name, createdAt: Date(), updatedAt: Date(),
            originDeviceId: "iphone", files: [primary, metadata]
        )
        let remoteMeta = try JSONSerialization.data(withJSONObject: ["transcription": "from phone"])
        let remote = RemoteRecordingBundle(manifest: manifest, files: [
            RemoteRecordingBundleFile(descriptor: primary, data: Data("audio".utf8)),
            RemoteRecordingBundleFile(descriptor: metadata, data: remoteMeta),
        ])

        let local = FileStore.recordingsDirectory().appendingPathComponent("\(name).m4a")
        try Data("audio".utf8).write(to: local)
        let sidecar = FileStore.metadataURL(forRecordingURL: local)
        try JSONSerialization.data(withJSONObject: [
            "syncId": syncId.rawValue, "summary": "made on the mac", "transcription": "old",
        ]).write(to: sidecar)
        let stateURL = base.appendingPathComponent("state.json")
        try await SyncStateStore(stateURL: stateURL).markDownloaded(
            syncId, localURL: local, updatedAt: Date().addingTimeInterval(-3600)
        )
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: stateURL),
            transport: FakeCloudTransport(remote: [remote])
        )

        try await service.downloadRemoteChanges(fullScan: true)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual(json["summary"] as? String, "made on the mac")
        XCTAssertEqual(json["transcription"] as? String, "from phone")
    }

    /// A phone still holding an edit this Mac took and then re-transcribed
    /// must not bring the old edit back.
    func testPhoneEchoOfArchivedEditKeepsNewerRun() {
        let record: [String: Any] = [
            "transcript": "mac re-run", "localTranscript": "live", "provider": "gemini",
            "previousRuns": [["transcript": "edited on the phone"]],
        ]
        let merged = CloudRecordingSyncService.mergedTranscription(record, phoneText: "edited on the phone")
        XCTAssertEqual(merged["transcript"] as? String, "mac re-run")
    }

    /// Two full records: the remote run wins, the local one is archived, and
    /// an empty remote transcript never wipes local text.
    func testRemoteRecordArchivesDifferentLocalRun() throws {
        let local: [String: Any] = [
            "transcript": "mac run", "provider": "parakeet", "model": "parakeet:ultra",
            "previousRuns": [["transcript": "older"]],
        ]
        let remote: [String: Any] = ["transcript": "phone run", "provider": "gemini"]
        let merged = CloudRecordingSyncService.mergedTranscription(local, remote: remote)
        XCTAssertEqual(merged["transcript"] as? String, "phone run")
        let runs = try XCTUnwrap(merged["previousRuns"] as? [[String: Any]])
        XCTAssertEqual(Set(runs.compactMap { $0["transcript"] as? String }), ["older", "mac run"])

        let same = CloudRecordingSyncService.mergedTranscription(["transcript": "phone run"], remote: remote)
        XCTAssertNil(same["previousRuns"])

        let silent = CloudRecordingSyncService.mergedTranscription(local, remote: ["transcript": "", "speechStatus": "noSpeech"])
        XCTAssertEqual(silent["transcript"] as? String, "mac run")
    }

    /// The phone's plain string is its live text or the user's edit. An echo
    /// of text the Mac already has must not replace the cloud run; a real edit
    /// wins and the cloud run goes to previousRuns. An unparseable remote
    /// sidecar must not land at all.
    func testRemoteSidecarCannotDestroyLocalTranscript() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let name = "Wimm_keep"
        let primary = RecordingBundleFile(
            role: .primary, relativePath: "Recordings/\(name).m4a", fileName: "\(name).m4a",
            byteSize: 5, modifiedAt: Date()
        )
        let metadata = RecordingBundleFile(
            role: .metadata, relativePath: "Recordings/\(name).meta.json", fileName: "\(name).meta.json",
            byteSize: 0, modifiedAt: Date()
        )
        let syncId = SyncRecordingID()
        let manifest = RecordingBundleManifest(
            syncId: syncId, filenamePrefix: name, createdAt: Date(), updatedAt: Date(),
            originDeviceId: "iphone", files: [primary, metadata]
        )
        let local = FileStore.recordingsDirectory().appendingPathComponent("\(name).m4a")
        try Data("audio".utf8).write(to: local)
        let sidecar = FileStore.metadataURL(forRecordingURL: local)
        let stateURL = base.appendingPathComponent("state.json")

        func download(_ remoteMeta: Data) async throws {
            try JSONSerialization.data(withJSONObject: [
                "syncId": syncId.rawValue, "transcription": ["transcript": "cloud run", "localTranscript": "live phone text",
                                  "provider": "gemini", "model": "gemini-3-flash"],
            ]).write(to: sidecar)
            try await SyncStateStore(stateURL: stateURL).markDownloaded(
                syncId, localURL: local, updatedAt: Date().addingTimeInterval(-3600)
            )
            let remote = RemoteRecordingBundle(manifest: manifest, files: [
                RemoteRecordingBundleFile(descriptor: primary, data: Data("audio".utf8)),
                RemoteRecordingBundleFile(descriptor: metadata, data: remoteMeta),
            ])
            try? await CloudRecordingSyncService(
                stateStore: SyncStateStore(stateURL: stateURL),
                transport: FakeCloudTransport(remote: [remote])
            ).downloadRemoteChanges(fullScan: true)
        }
        func transcript() throws -> String? {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
            return (json?["transcription"] as? [String: Any])?["transcript"] as? String
        }

        try await download(JSONSerialization.data(withJSONObject: ["transcription": "live phone text", "title": "t"]))
        XCTAssertEqual(try transcript(), "cloud run")
        let merged = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        XCTAssertEqual(merged?["title"] as? String, "t", "the remote update must actually have been applied")

        try await download(JSONSerialization.data(withJSONObject: ["transcription": "edited on the phone"]))
        XCTAssertEqual(try transcript(), "edited on the phone")
        let edited = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        let record = try XCTUnwrap(edited["transcription"] as? [String: Any])
        XCTAssertNil(record["provider"])
        let archived = try XCTUnwrap(record["previousRuns"] as? [[String: Any]])
        XCTAssertEqual(archived.last?["transcript"] as? String, "cloud run")

        try await download(Data("not json".utf8))
        XCTAssertEqual(try transcript(), "cloud run")
    }

    /// A transcript or card written after the first upload has to reach the
    /// other device; before, a note went up exactly once.
    func testLocalEditAfterUploadIsUploadedAgain() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let recording = FileStore.recordingsDirectory().appendingPathComponent("Wimm_edited.m4a")
        try Data("audio".utf8).write(to: recording)
        let transport = FakeCloudTransport()
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: base.appendingPathComponent("state.json")),
            transport: transport
        )
        _ = try await service.enqueueNewRecording(recording)
        try await service.syncNow()
        XCTAssertEqual(transport.uploaded.count, 1)

        try await service.syncNow()
        XCTAssertEqual(transport.uploaded.count, 1, "an unchanged note must not go up again")

        let sidecar = FileStore.metadataURL(forRecordingURL: recording)
        try FileStore.mutateSidecar(at: sidecar) { json in
            json["transcription"] = "written later"
            return true
        }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: sidecar.path)
        try await service.syncNow()

        XCTAssertEqual(transport.uploaded.count, 2)
    }

    func testLegacyDownloadedEntryIsBaselinedNotUploaded() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let recording = FileStore.recordingsDirectory().appendingPathComponent("Wimm_from_phone.m4a")
        try Data("audio".utf8).write(to: recording)
        let syncId = try RecordingSyncMetadata.ensureSyncID(for: recording)
        let stateURL = base.appendingPathComponent("state.json")
        try await SyncStateStore(stateURL: stateURL).markDownloaded(
            syncId, localURL: recording, updatedAt: Date().addingTimeInterval(-86_400)
        )
        let transport = FakeCloudTransport()
        let service = CloudRecordingSyncService(stateStore: SyncStateStore(stateURL: stateURL), transport: transport)

        try await service.syncNow()
        try await service.syncNow()

        XCTAssertTrue(transport.uploaded.isEmpty)
    }

    func testUpdatedRemoteSidecarDoesNotRedownloadUnchangedAudio() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let name = "Wimm_same_audio"
        let audio = Data("audio-bytes".utf8)
        let primary = RecordingBundleFile(
            role: .primary, relativePath: "Recordings/\(name).m4a", fileName: "\(name).m4a",
            byteSize: UInt64(audio.count), modifiedAt: Date()
        )
        let metadata = RecordingBundleFile(
            role: .metadata, relativePath: "Recordings/\(name).meta.json", fileName: "\(name).meta.json",
            byteSize: 0, modifiedAt: Date()
        )
        let syncId = SyncRecordingID()
        let remote = RemoteRecordingBundle(
            manifest: RecordingBundleManifest(
                syncId: syncId, filenamePrefix: name, createdAt: Date(), updatedAt: Date(),
                originDeviceId: "iphone", files: [primary, metadata]
            ),
            files: [
                RemoteRecordingBundleFile(descriptor: primary, data: audio),
                RemoteRecordingBundleFile(
                    descriptor: metadata,
                    data: try JSONSerialization.data(withJSONObject: ["transcription": "new"])
                ),
            ]
        )
        let local = FileStore.recordingsDirectory().appendingPathComponent("\(name).m4a")
        try audio.write(to: local)
        _ = try RecordingSyncMetadata.setSyncID(syncId, for: local, now: Date())
        let stateURL = base.appendingPathComponent("state.json")
        try await SyncStateStore(stateURL: stateURL).markDownloaded(
            syncId, localURL: local, updatedAt: Date().addingTimeInterval(-3600)
        )
        let transport = FakeCloudTransport(remote: [remote])
        let service = CloudRecordingSyncService(stateStore: SyncStateStore(stateURL: stateURL), transport: transport)

        let changed = try await service.downloadRemoteChanges(fullScan: true)

        XCTAssertTrue(changed)
        XCTAssertEqual(transport.skippedFiles, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: local))
        ) as? [String: Any])
        XCTAssertEqual(json["transcription"] as? String, "new")
        XCTAssertEqual(try Data(contentsOf: local), audio)
    }

    /// One digit replaced: same byte count, different text. Size alone used to
    /// call the file unchanged and the edit never arrived.
    func testRemoteTextEditOfSameSizeIsDownloaded() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let name = "Wimm_same_size_text"
        let installedAt = Date().addingTimeInterval(-7200)
        let edited = Data("Hausnummer 18".utf8)
        let primary = RecordingBundleFile(
            role: .primary, relativePath: "Recordings/\(name).md", fileName: "\(name).md",
            byteSize: UInt64(edited.count), modifiedAt: Date().addingTimeInterval(-60)
        )
        let metadata = RecordingBundleFile(
            role: .metadata, relativePath: "Recordings/\(name).meta.json", fileName: "\(name).meta.json",
            byteSize: 0, modifiedAt: Date()
        )
        let syncId = SyncRecordingID()
        let remote = RemoteRecordingBundle(
            manifest: RecordingBundleManifest(
                syncId: syncId, filenamePrefix: name, createdAt: installedAt, updatedAt: Date(),
                originDeviceId: "iphone", files: [primary, metadata]
            ),
            files: [
                RemoteRecordingBundleFile(descriptor: primary, data: edited),
                RemoteRecordingBundleFile(descriptor: metadata, data: try JSONSerialization.data(withJSONObject: [:])),
            ]
        )
        let local = FileStore.recordingsDirectory().appendingPathComponent("\(name).md")
        try Data("Hausnummer 17".utf8).write(to: local)
        _ = try RecordingSyncMetadata.setSyncID(syncId, for: local, now: installedAt)
        XCTAssertTrue(FileStore.trySetFileDates(local, created: nil, modified: installedAt))
        let stateURL = base.appendingPathComponent("state.json")
        try await SyncStateStore(stateURL: stateURL).markDownloaded(
            syncId, localURL: local, updatedAt: installedAt
        )
        let transport = FakeCloudTransport(remote: [remote])
        let service = CloudRecordingSyncService(stateStore: SyncStateStore(stateURL: stateURL), transport: transport)

        _ = try await service.downloadRemoteChanges(fullScan: true)

        XCTAssertEqual(transport.skippedFiles, 0)
        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "Hausnummer 18")
    }

    func testRemoteNameConflictDoesNotOverwriteLocalFile() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let local = FileStore.recordingsDirectory().appendingPathComponent("same-name.m4a")
        try Data("local".utf8).write(to: local)
        _ = try RecordingSyncMetadata.ensureSyncID(for: local)

        let remoteSyncId = SyncRecordingID()
        let descriptor = RecordingBundleFile(
            role: .primary,
            relativePath: FileStore.relativePath(for: local),
            fileName: local.lastPathComponent,
            byteSize: 6,
            modifiedAt: Date()
        )
        let manifest = RecordingBundleManifest(
            syncId: remoteSyncId,
            filenamePrefix: "same-name",
            createdAt: Date(),
            updatedAt: Date(),
            originDeviceId: "remote",
            files: [descriptor]
        )
        let remote = RemoteRecordingBundle(
            manifest: manifest,
            files: [RemoteRecordingBundleFile(descriptor: descriptor, data: Data("remote".utf8))]
        )
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: base.appendingPathComponent("state.json")),
            transport: FakeCloudTransport(remote: [remote])
        )

        try await service.downloadRemoteChanges()

        XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "local")
        let shortID = String(
            remoteSyncId.rawValue
                .replacingOccurrences(of: "-", with: "")
                .uppercased()
                .prefix(8)
        )
        let conflictFiles = try FileManager.default.contentsOfDirectory(at: FileStore.recordingsDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent == "same-name_\(shortID).m4a" }
        XCTAssertEqual(conflictFiles.count, 1)
        XCTAssertEqual(try String(contentsOf: conflictFiles[0], encoding: .utf8), "remote")
    }

    func testRemoteNameConflictRenamesWholeBundleAndRewritesMetadataPaths() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let local = FileStore.recordingsDirectory().appendingPathComponent("same-name.m4a")
        try Data("local".utf8).write(to: local)
        _ = try RecordingSyncMetadata.ensureSyncID(for: local)

        let remoteSyncId = SyncRecordingID(
            rawValue: "6A03CBEF-1234-5678-9ABC-DEF012345678"
        )
        let primaryDescriptor = RecordingBundleFile(
            role: .primary,
            relativePath: "Recordings/same-name.m4a",
            fileName: "same-name.m4a",
            byteSize: 6,
            modifiedAt: Date()
        )
        let metadataDescriptor = RecordingBundleFile(
            role: .metadata,
            relativePath: "Recordings/same-name.meta.json",
            fileName: "same-name.meta.json",
            byteSize: 0,
            modifiedAt: Date()
        )
        let attachmentDescriptor = RecordingBundleFile(
            role: .attachment,
            relativePath: "Recordings/same-name_Attach_photo.heic",
            fileName: "same-name_Attach_photo.heic",
            byteSize: 5,
            modifiedAt: Date()
        )
        let metadata: [String: Any] = [
            "recordingURL": "Recordings/same-name.m4a",
            "noteCard": ["note_file": "same-name.m4a"],
            "attachments": [["url": "Recordings/same-name_Attach_photo.heic"]],
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata)
        let manifest = RecordingBundleManifest(
            syncId: remoteSyncId,
            filenamePrefix: "same-name",
            createdAt: Date(),
            updatedAt: Date(),
            originDeviceId: "remote",
            files: [primaryDescriptor, metadataDescriptor, attachmentDescriptor]
        )
        let remote = RemoteRecordingBundle(
            manifest: manifest,
            files: [
                RemoteRecordingBundleFile(
                    descriptor: primaryDescriptor,
                    data: Data("remote".utf8)
                ),
                RemoteRecordingBundleFile(
                    descriptor: metadataDescriptor,
                    data: metadataData
                ),
                RemoteRecordingBundleFile(
                    descriptor: attachmentDescriptor,
                    data: Data("image".utf8)
                ),
            ]
        )
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: base.appendingPathComponent("state.json")),
            transport: FakeCloudTransport(remote: [remote])
        )

        try await service.downloadRemoteChanges()

        let renamedBase = "same-name_6A03CBEF"
        let remotePrimary = FileStore.recordingsDirectory()
            .appendingPathComponent("\(renamedBase).m4a")
        let remoteMetadata = FileStore.recordingsDirectory()
            .appendingPathComponent("\(renamedBase).meta.json")
        let remoteAttachment = FileStore.recordingsDirectory()
            .appendingPathComponent("\(renamedBase)_Attach_photo.heic")
        XCTAssertTrue(FileManager.default.fileExists(atPath: remotePrimary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteMetadata.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: remoteAttachment.path))

        let installedData = try Data(contentsOf: remoteMetadata)
        let installed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: installedData) as? [String: Any]
        )
        XCTAssertEqual(
            installed["recordingURL"] as? String,
            "Recordings/\(renamedBase).m4a"
        )
        XCTAssertEqual(
            (installed["noteCard"] as? [String: Any])?["note_file"] as? String,
            "\(renamedBase).m4a"
        )
        XCTAssertEqual(
            ((installed["attachments"] as? [[String: Any]])?.first)?["url"] as? String,
            "Recordings/\(renamedBase)_Attach_photo.heic"
        )
        XCTAssertEqual(
            RecordingSyncMetadata.readSyncID(for: remotePrimary),
            remoteSyncId
        )
    }

    func testRemoteAbsoluteDevicePathInstallsIntoLocalRecordingsDirectory() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let descriptor = RecordingBundleFile(
            role: .primary,
            relativePath: "/var/mobile/Containers/Shared/AppGroup/example/Wimm/Recordings/phone.m4a",
            fileName: "phone.m4a",
            byteSize: 5,
            modifiedAt: Date()
        )
        let manifest = RecordingBundleManifest(
            syncId: SyncRecordingID(),
            filenamePrefix: "phone",
            createdAt: Date(),
            updatedAt: Date(),
            originDeviceId: "iphone",
            files: [descriptor]
        )
        let remote = RemoteRecordingBundle(
            manifest: manifest,
            files: [RemoteRecordingBundleFile(descriptor: descriptor, data: Data("audio".utf8))]
        )
        let service = CloudRecordingSyncService(
            stateStore: SyncStateStore(stateURL: base.appendingPathComponent("state.json")),
            transport: FakeCloudTransport(remote: [remote])
        )

        try await service.downloadRemoteChanges()

        let installed = FileStore.recordingsDirectory().appendingPathComponent("phone.m4a")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "audio")
    }

    func testBackfillDryRunDoesNotMutateMetadata() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let recording = FileStore.recordingsDirectory().appendingPathComponent("old.m4a")
        try Data("audio".utf8).write(to: recording)

        let service = RecordingSyncBackfillService()
        let summary = await service.run(options: RecordingSyncBackfillOptions(dryRun: true, limit: 1))

        XCTAssertEqual(summary.eligible, 1)
        XCTAssertNil(RecordingSyncMetadata.readSyncID(for: recording))
    }

    func testBackfillSkipsRenderedPDFPreviewAsSeparateRecording() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let pdf = FileStore.recordingsDirectory().appendingPathComponent("Scan_20150518_111223.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        // First-page render written by DocumentImportService; ships as a .screenshot
        // inside the PDF's own bundle, so it must not be scanned as a primary too.
        try Data("preview".utf8).write(to: FileStore.screenshotURL(forRecordingURL: pdf))

        let service = RecordingSyncBackfillService()
        let summary = await service.run(options: RecordingSyncBackfillOptions(dryRun: true))

        XCTAssertEqual(summary.scanned, 1)
        XCTAssertEqual(summary.eligible, 1)
    }
}

private final class FakeCloudTransport: CloudRecordingSyncTransport, @unchecked Sendable {
    private let remote: [RemoteRecordingBundle]
    private(set) var uploaded: [SyncRecordingID] = []
    private(set) var fetchedBundles: [SyncRecordingID] = []
    private(set) var skippedFiles = 0

    init(remote: [RemoteRecordingBundle] = []) {
        self.remote = remote
    }

    func upload(bundle: LocalRecordingBundle) async throws -> String? {
        uploaded.append(bundle.manifest.syncId)
        return "fake-change-tag"
    }

    func fetchChangeSummaries(since: Date?) async throws -> [RemoteRecordingSummary] {
        remote
            .filter { since == nil || $0.manifest.updatedAt > since! }
            .map {
                RemoteRecordingSummary(
                    syncId: $0.manifest.syncId,
                    updatedAt: $0.manifest.updatedAt,
                    isDeleted: $0.manifest.isDeleted,
                    filenamePrefix: $0.manifest.filenamePrefix
                )
            }
    }

    func fetchBundle(
        syncId: SyncRecordingID,
        skipping: @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool
    ) async throws -> RemoteRecordingBundle {
        fetchedBundles.append(syncId)
        guard let bundle = remote.first(where: { $0.manifest.syncId == syncId }) else {
            throw RecordingSyncError.invalidCloudPayload("no such record")
        }
        let kept = bundle.files.filter { !skipping(bundle.manifest, $0.descriptor) }
        skippedFiles += bundle.files.count - kept.count
        return RemoteRecordingBundle(manifest: bundle.manifest, files: kept)
    }

    func markDeleted(syncId: SyncRecordingID, updatedAt: Date) async throws {}
}
