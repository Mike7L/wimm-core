import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// The sync engine itself: enqueue, upload, download, install, tombstone.

public protocol CloudRecordingSyncTransport: Sendable {
    func upload(bundle: LocalRecordingBundle) async throws -> String?
    /// Identity + version of every record whose `updatedAt` is after `since`
    /// (all of them for nil), with no assets.
    func fetchChangeSummaries(since: Date?) async throws -> [RemoteRecordingSummary]
    /// The full bundle, minus the files `skipping` says this device already
    /// holds unchanged (their assets are not downloaded).
    func fetchBundle(
        syncId: SyncRecordingID,
        skipping: @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool
    ) async throws -> RemoteRecordingBundle
    func markDeleted(syncId: SyncRecordingID, updatedAt: Date) async throws
    /// Asks the cloud to push a silent notification to this device whenever
    /// any recording record changes, so other devices need not wait for a poll.
    func ensureChangeSubscription() async throws
}

public extension CloudRecordingSyncTransport {
    func ensureChangeSubscription() async throws {}
}

public actor CloudRecordingSyncService {
    private let builder: RecordingBundleBuilder
    private let stateStore: SyncStateStore
    private let transport: any CloudRecordingSyncTransport
    /// Primary files installed by the last downloads, kept until a caller
    /// drains them. Notes captured on another device arrive unprocessed, so
    /// the desktop needs to know which files still need OCR / note cards.
    private var freshlyDownloaded: [URL] = []
    /// The personal document's snapshot, carried along by every sync; only
    /// the live service has one, so tests never reach a real document.
    public nonisolated let documentSync: PersonalDocumentSync?

    public init(
        builder: RecordingBundleBuilder = RecordingBundleBuilder(),
        stateStore: SyncStateStore = SyncStateStore(),
        transport: any CloudRecordingSyncTransport,
        documentSync: PersonalDocumentSync? = nil
    ) {
        self.builder = builder
        self.stateStore = stateStore
        self.transport = transport
        self.documentSync = documentSync
    }

    /// The app's one sync engine. Every caller must share it: each instance
    /// holds its own `SyncStateStore` and journal sequence, so a second writer
    /// (the Mac app used to make three) could overwrite the first one's progress.
    public static func live(
        containerIdentifier: String = "iCloud.com.micha.wimm"
    ) -> CloudRecordingSyncService? {
        containerIdentifier == defaultContainerIdentifier
            ? sharedLive
            : makeLive(containerIdentifier: containerIdentifier)
    }

    private static let defaultContainerIdentifier = "iCloud.com.micha.wimm"
    private static let sharedLive = makeLive(containerIdentifier: defaultContainerIdentifier)

    private static func makeLive(containerIdentifier: String) -> CloudRecordingSyncService? {
        #if canImport(CloudKit)
        #if os(macOS)
        guard hasCloudKitEntitlement(containerIdentifier: containerIdentifier) else {
            log("[CloudSync] disabled: missing CloudKit entitlement for \(containerIdentifier)")
            return nil
        }
        #endif
        return CloudRecordingSyncService(
            transport: CloudKitRecordingSyncTransport(containerIdentifier: containerIdentifier),
            documentSync: PersonalDocumentSync.makeLive(containerIdentifier: containerIdentifier)
        )
        #else
        return nil
        #endif
    }

    #if os(macOS) && canImport(Security)
    private static func hasCloudKitEntitlement(containerIdentifier: String) -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return false
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let signingInfo = info as? [String: Any],
              let entitlements = signingInfo[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return false
        }

        let services = entitlements["com.apple.developer.icloud-services"] as? [String]
        let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String]
        return services?.contains("CloudKit") == true && containers?.contains(containerIdentifier) == true
    }
    #elseif os(macOS)
    private static func hasCloudKitEntitlement(containerIdentifier: String) -> Bool {
        false
    }
    #endif

    /// Registers for the cloud's silent change pushes. Idempotent; a failure
    /// only means this device falls back to polling.
    public func subscribeToChanges() async {
        do { try await transport.ensureChangeSubscription() }
        catch { log("[CloudSync] push subscription failed: \(error)") }
    }

    public func enqueueNewRecording(_ recordingURL: URL) async throws -> SyncRecordingID {
        let bundle = try builder.build(for: recordingURL, assignSyncID: true)
        try await stateStore.enqueueUpload(
            syncId: bundle.manifest.syncId,
            localURL: recordingURL,
            updatedAt: bundle.manifest.updatedAt
        )
        return bundle.manifest.syncId
    }

    /// Two-way sync. Local edits are queued first, then remote changes are
    /// merged in, then the queue is uploaded — so a note changed on both
    /// devices goes up as the merge of both, not as either side alone.
    /// Returns whether downloading remote changes modified the local library;
    /// callers can avoid rebuilding their derived views after a no-op sync.
    /// `fullScan` reconciles against every cloud record instead of the recent
    /// window — cheap (no assets). `recentOnly` narrows the window to
    /// `quickLookback`, for frequent polls that only need fresh uploads.
    @discardableResult
    public func syncNow(fullScan: Bool = false, recentOnly: Bool = false) async throws -> Bool {
        try await stateStore.validatePersistence()
        if fullScan { await enqueueUntracked() }
        _ = try await enqueueLocalChangesPersisted(limit: 200)
        var downloadError: Error?
        var didApplyRemoteChanges = false
        do {
            didApplyRemoteChanges = try await downloadRemoteChanges(fullScan: fullScan, recentOnly: recentOnly)
        } catch {
            downloadError = error
        }

        try await uploadPending()
        await documentSync?.syncNow()

        if let downloadError {
            throw downloadError
        }
        return didApplyRemoteChanges
    }

    public func uploadPending() async throws {
        try await stateStore.validatePersistence()
        _ = try await flushPendingDeletes()
        let pending = await stateStore.entries(with: [.pendingUpload, .failed])
        let directorySnapshot = RecordingBundleDirectorySnapshot()
        for entry in pending {
            let localURL = FileStore.resolveRelativePath(entry.localRelativePath)
            if Self.isInTrash(localURL) { continue }
            // Never send another record's file under this id: it would
            // overwrite this record in the cloud with someone else's note.
            if Self.isOwnedByAnotherRecord(localURL, syncId: entry.syncId) { continue }
            do {
                let bundle = try builder.build(for: localURL, assignSyncID: true, directorySnapshot: directorySnapshot)
                // Read after build: ensureSyncID may have just touched the sidecar.
                let version = Self.localVersion(of: localURL)
                let changeTag = try await transport.upload(bundle: bundle)
                try await stateStore.markUploaded(entry.syncId, changeTag: changeTag, updatedAt: Date(), localModifiedAt: version)
            } catch {
                try await stateStore.validatePersistence()
                try? await stateStore.markFailed(entry.syncId, error: error)
            }
        }
    }

    /// Newest of the primary file and its sidecar — where every local edit
    /// (transcript, card, OCR, attachment list) lands.
    static func localVersion(of primaryURL: URL) -> Date? {
        let fm = FileManager.default
        let dates = [primaryURL, FileStore.metadataURL(forRecordingURL: primaryURL)].compactMap {
            (try? fm.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        return dates.max()
    }

    /// Queues notes edited on this device since they last matched the cloud.
    /// Before this, a note went up once — usually right after recording,
    /// before its transcript existed — and nothing it gained later ever
    /// reached the other device.
    @discardableResult
    public func enqueueLocalChanges(limit: Int = 200) async -> Int {
        do { return try await enqueueLocalChangesPersisted(limit: limit) }
        catch {
            log("[CloudSync] enqueue local changes failed: \(error)")
            return 0
        }
    }

    /// syncNow must not download over local edits whose queue write failed.
    private func enqueueLocalChangesPersisted(limit: Int) async throws -> Int {
        try await stateStore.validatePersistence()
        let entries = await stateStore.entries(with: [.uploaded, .downloaded])
        var baselines: [SyncRecordingID: Date] = [:]
        var uploads: [(syncId: SyncRecordingID, localURL: URL, updatedAt: Date)] = []
        for entry in entries where uploads.count < limit {
            let url = FileStore.resolveRelativePath(entry.localRelativePath)
            if Self.isInTrash(url) { continue }
            if Self.isOwnedByAnotherRecord(url, syncId: entry.syncId) { continue }
            guard let version = Self.localVersion(of: url) else { continue }
            let changed: Bool
            if let known = entry.localModifiedAt {
                changed = Self.isNewer(version, than: known)
            } else {
                // Ledger entries from before versions were tracked. An upload's
                // `updatedAt` is when it went up, so anything written later is a
                // real edit. A download's is the remote stamp, which says nothing
                // about local writes — take the current state as the baseline.
                changed = entry.status == .uploaded
                    && version.timeIntervalSince(entry.updatedAt) > Self.legacyEditSlack
                if !changed { baselines[entry.syncId] = version }
            }
            guard changed else { continue }
            uploads.append((entry.syncId, url, Date()))
        }
        try await stateStore.enqueueUploads(uploads, localVersions: baselines)
        let enqueued = uploads.count
        if enqueued > 0 { log("[CloudSync] queued \(enqueued) locally changed notes") }
        return enqueued
    }

    /// The file's sidecar names a different record. Two cloud records with the
    /// same file name (one PDF imported on both devices) used to install into
    /// one file and then overwrite each other on every sync.
    static func isOwnedByAnotherRecord(_ url: URL, syncId: SyncRecordingID) -> Bool {
        guard let owner = RecordingSyncMetadata.readSyncID(for: url) else { return false }
        return owner != syncId
    }

    /// An upload writes the sidecar's syncId a moment before the ledger entry.
    static let legacyEditSlack: TimeInterval = 5

    /// Gives a sync id to notes that never got one — recorded while sync was
    /// off (an unsigned dev build, a failed enqueue) — and queues them.
    @discardableResult
    public func enqueueUntracked(limit: Int = 200) async -> Int {
        let summary = await RecordingSyncBackfillService(builder: builder, stateStore: stateStore).run(
            options: RecordingSyncBackfillOptions(dryRun: false, limit: limit, onlyMissingSyncID: true, batchSize: limit)
        )
        if summary.enqueued > 0 { log("[CloudSync] queued \(summary.enqueued) notes that were never synced") }
        return summary.enqueued
    }

    /// How far before the last sync an incremental scan reaches back. Builds
    /// before 2026-10-20 stamped a record with the uploader's file time, not
    /// when it reached the server, so "after the last sync" missed every note
    /// uploaded after the other device had synced past its file time. Newer
    /// uploads carry the upload time; the window and the periodic full scan
    /// cover records from older builds.
    static let incrementalLookback: TimeInterval = 14 * 24 * 3600
    /// Uploads now carry their upload time, so a fresh one is always inside a
    /// few minutes of the last sync; the margin covers device clock skew.
    static let quickLookback: TimeInterval = 10 * 60

    @discardableResult
    public func downloadRemoteChanges(fullScan: Bool = false, recentOnly: Bool = false) async throws -> Bool {
        try await stateStore.validatePersistence()
        let state = await stateStore.snapshot()
        let lookback = recentOnly ? Self.quickLookback : Self.incrementalLookback
        let since = fullScan ? nil : state.lastSyncAt.map { $0.addingTimeInterval(-lookback) }
        let scanStartedAt = Date()
        let summaries = try await transport.fetchChangeSummaries(since: since)
        var didApplyRemoteChanges = false
        var failures = 0
        var localSyncIDs: [String: URL]?
        for summary in summaries {
            let localEntry = await stateStore.entry(for: summary.syncId)
            if let localEntry, !Self.isNewer(summary.updatedAt, than: localEntry.updatedAt) {
                continue
            }
            do {
                if summary.isDeleted {
                    try await applyTombstone(syncId: summary.syncId, updatedAt: summary.updatedAt)
                    didApplyRemoteChanges = true
                    continue
                }
                if localEntry == nil {
                    // A note already on disk whose ledger entry was lost:
                    // record it rather than re-installing over local analysis.
                    if localSyncIDs == nil { localSyncIDs = Self.indexLocalSyncIDs() }
                    if let existing = localSyncIDs?[summary.syncId.rawValue] {
                        try await stateStore.markDownloaded(summary.syncId, localURL: existing, updatedAt: summary.updatedAt)
                        continue
                    }
                }
                // Old ledgers can point two records at one file; install the
                // other record beside it instead of over it.
                let existingLocalURL = localEntry
                    .map { FileStore.resolveRelativePath($0.localRelativePath) }
                    .flatMap { Self.isOwnedByAnotherRecord($0, syncId: summary.syncId) ? nil : $0 }
                let remote = try await transport.fetchBundle(
                    syncId: summary.syncId,
                    skipping: Self.reusableLocalFile(existingLocalURL: existingLocalURL)
                )
                let primaryURL = try install(remote, existingLocalURL: existingLocalURL)
                // Stamp with the record's own time: that is what the next scan
                // compares against.
                if let localEntry, [.pendingUpload, .failed].contains(localEntry.status) {
                    // Edited here too: the merged sidecar still has to go up.
                    try await stateStore.enqueueUpload(syncId: summary.syncId, localURL: primaryURL, updatedAt: summary.updatedAt)
                } else {
                    try await stateStore.markDownloaded(
                        summary.syncId,
                        localURL: primaryURL,
                        updatedAt: summary.updatedAt,
                        localModifiedAt: Self.localVersion(of: primaryURL)
                    )
                }
                freshlyDownloaded.append(primaryURL)
                didApplyRemoteChanges = true
            } catch {
                try await stateStore.validatePersistence()
                failures += 1
                log("[CloudSync] download \(summary.syncId) failed: \(error)")
            }
        }
        // A failed item is retried next time only if the window still covers it.
        if failures == 0 {
            try await stateStore.updateLastSyncAt(scanStartedAt)
        }
        return didApplyRemoteChanges
    }

    /// The ledger and the manifest store whole-second ISO dates, CloudKit keeps
    /// milliseconds. Compared raw, every record looked newer than its ledger
    /// entry and was re-installed on every scan.
    static func isNewer(_ remote: Date, than local: Date) -> Bool {
        remote.timeIntervalSince1970.rounded(.down) > local.timeIntervalSince1970.rounded(.down)
    }

    /// A file of an already-installed note that is the size the cloud lists
    /// and not older than the cloud's copy needs no download. Size alone is
    /// not enough: a text note edited without changing its byte count (one
    /// digit replaced) never reached the other device. The sidecar always
    /// downloads — it is what changes.
    static func reusableLocalFile(
        existingLocalURL: URL?
    ) -> @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool {
        guard let existingLocalURL else { return { _, _ in false } }
        let localBase = existingLocalURL.deletingPathExtension().lastPathComponent
        let directory = existingLocalURL.deletingLastPathComponent()
        return { manifest, descriptor in
            guard descriptor.role != .metadata else { return false }
            let remoteBase = remoteBase(of: manifest)
            let local = directory.appendingPathComponent(
                localFileName(for: descriptor, remoteBase: remoteBase, localBase: localBase)
            )
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: local.path),
                  attributes[.size] as? UInt64 == descriptor.byteSize,
                  let modified = attributes[.modificationDate] as? Date else { return false }
            // `install` stamps a downloaded file with the cloud's time, so an
            // unchanged file compares equal; a file touched locally is newer.
            return !isNewer(descriptor.modifiedAt, than: modified)
        }
    }

    static func remoteBase(of manifest: RecordingBundleManifest) -> String {
        if !manifest.filenamePrefix.isEmpty { return manifest.filenamePrefix }
        return manifest.files.first(where: { $0.role == .primary })?.fileName.deletingPathExtension ?? ""
    }

    /// syncId → primary file for every note in the recordings directory that
    /// carries one. Only built when the cloud lists a record the ledger lacks.
    private static func indexLocalSyncIDs() -> [String: URL] {
        let directory = FileStore.recordingsDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var index: [String: URL] = [:]
        for url in files where !url.lastPathComponent.hasSuffix(".json")
            && !FileStore.isDerivedAudioFile(url) {
            if let syncId = RecordingSyncMetadata.readSyncID(for: url), index[syncId.rawValue] == nil {
                index[syncId.rawValue] = url
            }
        }
        return index
    }

    /// Returns the files installed by downloads since the last call and clears
    /// the list, so each downloaded note is handed to post-sync processing once.
    public func drainFreshlyDownloaded() -> [URL] {
        defer { freshlyDownloaded.removeAll() }
        return freshlyDownloaded
    }

    /// The note was just moved to Trash. The syncId is read from the trashed
    /// sidecar (it travels with the note); the ledger keeps `originalURL`.
    /// Returns false for a note that never had a sync id — nothing to tell.
    @discardableResult
    public func markTrashed(trashedURL: URL, originalURL: URL) async throws -> Bool {
        guard let syncId = RecordingSyncMetadata.readSyncID(for: trashedURL) else { return false }
        // The note-id fallback names notes that never reached the cloud too;
        // only a sync id in the sidecar or the ledger means a record exists.
        let inLedger = await stateStore.entry(for: syncId) != nil
        let known = RecordingSyncMetadata.readExplicitSyncID(for: trashedURL) != nil
        guard known || inLedger else { return false }
        _ = try await markDeleted([(syncId, originalURL)])
        return true
    }

    /// Queues the tombstones durably first, then tries to send them. Being
    /// offline is not an error here: whatever did not go up stays
    /// `.pendingDelete` and the next `uploadPending` / `syncNow` retries it.
    /// Throws only when the ledger cannot record the deletion.
    @discardableResult
    public func markDeleted(_ deletions: [(syncId: SyncRecordingID, localURL: URL)]) async throws -> (sent: Int, failed: Int) {
        guard !deletions.isEmpty else { return (0, 0) }
        try await stateStore.enqueueDeletions(deletions)
        let ids = Set(deletions.map(\.syncId))
        return try await flushPendingDeletes(only: ids)
    }

    /// A note came back from Trash: send it up again. The upload stamps the
    /// record with a fresh `updatedAt` and `isDeleted = false`, so devices
    /// that applied the tombstone install it again. A restore before the
    /// tombstone left this device simply replaces the queued delete.
    @discardableResult
    public func markRestored(recordingURL: URL) async throws -> Bool {
        guard let syncId = RecordingSyncMetadata.readSyncID(for: recordingURL) else { return false }
        try await stateStore.enqueueUpload(syncId: syncId, localURL: recordingURL)
        return true
    }

    /// Sends queued tombstones. Each one is stamped with the time it actually
    /// goes up: other devices scan "updated since their last sync", and a
    /// delete sent days after it happened must still count as new.
    @discardableResult
    public func flushPendingDeletes(only ids: Set<SyncRecordingID>? = nil) async throws -> (sent: Int, failed: Int) {
        try await stateStore.validatePersistence()
        var sent = 0
        var failed = 0
        for entry in await stateStore.entries(with: [.pendingDelete]) {
            if let ids, !ids.contains(entry.syncId) { continue }
            let stamp = Date()
            do {
                try await transport.markDeleted(syncId: entry.syncId, updatedAt: stamp)
                try await stateStore.markUploaded(entry.syncId, updatedAt: stamp)
                sent += 1
            } catch {
                try await stateStore.validatePersistence()
                try? await stateStore.markDeleteFailed(entry.syncId, error: error)
                failed += 1
                log("[CloudSync] tombstone \(entry.syncId) failed: \(error)")
            }
        }
        return (sent, failed)
    }

    /// A file inside Trash is never sent up as a live note.
    static func isInTrash(_ url: URL) -> Bool {
        let trash = FileStore.trashDirectory().standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(trash.hasSuffix("/") ? trash : trash + "/")
    }

    private func applyTombstone(syncId: SyncRecordingID, updatedAt: Date) async throws {
        guard let entry = await stateStore.entry(for: syncId) else { return }
        let localURL = FileStore.resolveRelativePath(entry.localRelativePath)
        if FileManager.default.fileExists(atPath: localURL.path) {
            _ = RecordingTrashSupport.moveToTrash(file: localURL)
        }
        try await stateStore.markDownloaded(syncId, localURL: localURL, updatedAt: updatedAt)
    }

    @discardableResult
    private func install(
        _ remote: RemoteRecordingBundle,
        existingLocalURL: URL?
    ) throws -> URL {
        let directory = FileStore.recordingsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The primary may have been skipped as already present, so name things
        // from the manifest rather than from the files that came down.
        guard let primary = remote.manifest.files.first(where: { $0.role == .primary })
            ?? remote.files.first(where: { $0.descriptor.role == .primary })?.descriptor else {
            throw RecordingSyncError.invalidCloudPayload("bundle has no primary file")
        }

        let remoteBase = Self.remoteBase(of: remote.manifest).isEmpty
            ? primary.fileName.deletingPathExtension
            : Self.remoteBase(of: remote.manifest)
        let primaryExtension = primary.fileName.pathExtension
        let localBase = chooseLocalBase(
            desiredBase: remoteBase,
            primaryExtension: primaryExtension,
            syncId: remote.manifest.syncId,
            existingLocalURL: existingLocalURL
        )

        var nameMap: [String: String] = [:]
        for descriptor in remote.manifest.files + remote.files.map(\.descriptor) {
            nameMap[descriptor.fileName] = Self.localFileName(
                for: descriptor,
                remoteBase: remoteBase,
                localBase: localBase
            )
        }

        var primaryURL: URL? = nameMap[primary.fileName].map { directory.appendingPathComponent($0) }
        for file in remote.files {
            guard let localName = nameMap[file.descriptor.fileName] else { continue }
            let destination = directory.appendingPathComponent(localName)
            if file.descriptor.role == .metadata {
                let data = remappedMetadata(
                    file.data,
                    nameMap: nameMap,
                    syncId: remote.manifest.syncId
                )
                guard let incoming = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RecordingSyncError.invalidCloudPayload("sidecar \(file.descriptor.fileName) is not a JSON object")
                }
                // Merge, never replace: the remote copy wins key by key,
                // but what only this device wrote (its analysis, OCR) is
                // not in the remote sidecar and must survive an update.
                try FileStore.mutateSidecar(at: destination) { current in
                    let localTranscription = current["transcription"]
                    current.merge(incoming) { _, remote in remote }
                    if let record = localTranscription as? [String: Any] {
                        if let phoneText = incoming["transcription"] as? String {
                            current["transcription"] = Self.mergedTranscription(record, phoneText: phoneText)
                        } else if let remote = incoming["transcription"] as? [String: Any] {
                            current["transcription"] = Self.mergedTranscription(record, remote: remote)
                        }
                    }
                    return true
                }
            } else {
                try file.data.write(to: destination, options: .atomic)
            }
            _ = FileStore.trySetFileDates(
                destination,
                created: remote.manifest.createdAt,
                modified: file.descriptor.modifiedAt
            )
            if file.descriptor.role == .primary {
                primaryURL = destination
            }
        }

        guard let primaryURL, FileManager.default.fileExists(atPath: primaryURL.path) else {
            throw RecordingSyncError.invalidCloudPayload("primary file was not installed")
        }
        try RecordingSyncMetadata.setSyncID(
            remote.manifest.syncId,
            for: primaryURL,
            now: remote.manifest.updatedAt
        )
        return primaryURL
    }

    private func chooseLocalBase(
        desiredBase: String,
        primaryExtension: String,
        syncId: SyncRecordingID,
        existingLocalURL: URL?
    ) -> String {
        if let existingLocalURL {
            return existingLocalURL.deletingPathExtension().lastPathComponent
        }

        let compactID = syncId.rawValue
            .replacingOccurrences(of: "-", with: "")
            .uppercased()
        let lengths = [8, 12, compactID.count]
        var candidates = [desiredBase]
        for length in lengths where length > 0 {
            let token = String(compactID.prefix(length))
            let short = String(compactID.prefix(min(8, compactID.count)))
            if !short.isEmpty, desiredBase.uppercased().hasSuffix("_\(short)") {
                candidates.append(
                    String(desiredBase.dropLast(short.count)) + token
                )
            } else {
                candidates.append("\(desiredBase)_\(token)")
            }
        }

        for candidate in candidates {
            let primary = FileStore.recordingsDirectory()
                .appendingPathComponent(candidate)
                .appendingPathExtension(primaryExtension)
            let metadata = FileStore.metadataURL(forRecordingURL: primary)
            let primaryExists = FileManager.default.fileExists(atPath: primary.path)
            let metadataExists = FileManager.default.fileExists(atPath: metadata.path)
            if !primaryExists && !metadataExists {
                return candidate
            }
            if RecordingSyncMetadata.readSyncID(for: primary) == syncId {
                return candidate
            }
        }

        let stableBase = candidates.last ?? desiredBase
        var index = 2
        while true {
            let candidate = "\(stableBase)_\(index)"
            let primary = FileStore.recordingsDirectory()
                .appendingPathComponent(candidate)
                .appendingPathExtension(primaryExtension)
            if !FileManager.default.fileExists(atPath: primary.path),
               !FileManager.default.fileExists(
                    atPath: FileStore.metadataURL(forRecordingURL: primary).path
               ) {
                return candidate
            }
            index += 1
        }
    }

    static func localFileName(
        for descriptor: RecordingBundleFile,
        remoteBase: String,
        localBase: String
    ) -> String {
        let name = descriptor.fileName
        if name == remoteBase
            || name.hasPrefix("\(remoteBase).")
            || name.hasPrefix("\(remoteBase)_") {
            return localBase + name.dropFirst(remoteBase.count)
        }

        switch descriptor.role {
        case .primary:
            return URL(fileURLWithPath: localBase)
                .appendingPathExtension(name.pathExtension)
                .lastPathComponent
        case .metadata:
            return "\(localBase).meta.json"
        case .attachment:
            return "\(localBase)_Attach_\(name)"
        case .screenshot:
            return "\(localBase)_screen_\(name)"
        case .mini, .other:
            return "\(localBase)_\(name)"
        }
    }

    /// The iPhone keeps `transcription` as a plain string: its live text, or
    /// the user's own edit of a text note. Text this Mac already holds is an
    /// echo and changes nothing; new text is the phone's edit and becomes the
    /// transcript, with the replaced run kept in `previousRuns`.
    static func mergedTranscription(_ record: [String: Any], phoneText: String) -> [String: Any] {
        let text = phoneText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Archived runs count too: a phone still holding an edit this Mac
        // already took and since re-transcribed must not bring it back.
        let archived = (record[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []).map { $0["transcript"] }
        let known = ([record["transcript"], record["localTranscript"]] + archived).compactMap {
            ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, !known.contains(text) else { return record }
        var merged = record
        archivePreviousRun(in: &merged, replacingWith: text)
        merged["transcript"] = text
        // Not a model's run any more: the old provider/model would mislabel it.
        merged.removeValue(forKey: "provider")
        merged.removeValue(forKey: "model")
        return merged
    }

    /// Both devices hold a full transcript record. The remote one wins, but a
    /// different local transcript joins its `previousRuns` instead of being
    /// dropped, and an empty remote transcript (no speech, not yet run) never
    /// replaces local text.
    static func mergedTranscription(_ local: [String: Any], remote: [String: Any]) -> [String: Any] {
        func text(_ value: Any?) -> String {
            (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let remoteText = text(remote["transcript"])
        guard !remoteText.isEmpty else { return text(local["transcript"]).isEmpty ? remote : local }
        var archive = local
        archivePreviousRun(in: &archive, replacingWith: remoteText)
        var runs = remote[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
        var seen = Set(runs.map { text($0["transcript"]) } + [remoteText])
        for run in archive[transcriptionPreviousRunsKey] as? [[String: Any]] ?? []
        where seen.insert(text(run["transcript"])).inserted {
            runs.append(run)
        }
        guard !runs.isEmpty else { return remote }
        trimPreviousRuns(&runs)
        var merged = remote
        merged[transcriptionPreviousRunsKey] = runs
        return merged
    }

    private func remappedMetadata(
        _ data: Data,
        nameMap: [String: String],
        syncId: SyncRecordingID
    ) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        func remapPath(_ raw: String) -> String {
            var result = raw
            for (remoteName, localName) in nameMap.sorted(by: { $0.key.count > $1.key.count }) {
                result = result.replacingOccurrences(of: remoteName, with: localName)
            }
            return result
        }

        let pathKeys: Set<String> = ["recordingURL", "note_file", "url", "audioPath"]
        func remap(_ value: Any, key: String? = nil) -> Any {
            if let string = value as? String, let key, pathKeys.contains(key) {
                return remapPath(string)
            }
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (nestedKey, nestedValue) in dictionary {
                    result[nestedKey] = remap(nestedValue, key: nestedKey)
                }
                return result
            }
            if let array = value as? [Any] {
                return array.map { remap($0) }
            }
            return value
        }

        json = remap(json) as? [String: Any] ?? json
        json[RecordingSyncMetadata.syncIdKey] = syncId.rawValue
        json[RecordingSyncMetadata.syncUpdatedAtKey] = wimmSyncDateString(Date())
        if UUID(uuidString: syncId.rawValue) != nil {
            json[RecordingIdentity.metadataKey] = syncId.rawValue
        }
        return (try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? data
    }
}

private extension String {
    var deletingPathExtension: String {
        (self as NSString).deletingPathExtension
    }

    var pathExtension: String {
        (self as NSString).pathExtension
    }
}
