import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// The CloudKit implementation of CloudRecordingSyncTransport.

#if canImport(CloudKit)
public final class CloudKitRecordingSyncTransport: CloudRecordingSyncTransport, @unchecked Sendable {
    private let database: CKDatabase

    public init(containerIdentifier: String = "iCloud.com.micha.wimm") {
        self.database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    public func upload(bundle: LocalRecordingBundle) async throws -> String? {
        let recordID = CKRecord.ID(recordName: bundle.manifest.syncId.rawValue)
        // Fetch only the bookkeeping fields: a full fetch downloaded every
        // asset of the record just to overwrite it. A partially fetched record
        // saves only the fields set below; the rest stay as they are.
        let existing = try? await fetch(recordID, desiredKeys: Self.bookkeepingKeys)
        let record = existing ?? CKRecord(recordType: "RecordingBundle", recordID: recordID)
        let previousFiles = existing.flatMap(Self.manifest(of:))?.files ?? []
        record["syncId"] = bundle.manifest.syncId.rawValue as CKRecordValue
        record["prefix"] = bundle.manifest.filenamePrefix as CKRecordValue
        record["createdAt"] = bundle.manifest.createdAt as NSDate
        // The upload time, not the manifest's file time: other devices scan
        // "updated since", and an old file uploaded today (a Voice Memos
        // import keeps its recording date) must count as new today. It is
        // also the version a newer copy is judged by.
        record["updatedAt"] = Date() as NSDate
        record["originDeviceId"] = bundle.manifest.originDeviceId as CKRecordValue
        record["schemaVersion"] = bundle.manifest.schemaVersion as CKRecordValue
        record["isDeleted"] = bundle.manifest.isDeleted as CKRecordValue

        let manifestData = try JSONEncoder.wimmSyncEncoder.encode(bundle.manifest)
        record["manifestJSON"] = String(data: manifestData, encoding: .utf8)! as CKRecordValue

        // CloudKit caps a record type at 256 fields and each asset takes 4
        // (asset/Role/Name/RelativePath), so bundles with 60+ attachments made
        // the save fail permanently. Keep the most important roles and drop the
        // attachment tail; the full file list stays in manifestJSON.
        let files = Self.prioritizedFiles(bundle.files, limit: Self.maxAssetsPerRecord)
        record["assetCount"] = files.count as CKRecordValue
        record["assetTruncated"] = (files.count < bundle.files.count) as CKRecordValue
        if files.count < bundle.files.count {
            log("[CloudSync] \(bundle.manifest.filenamePrefix): uploading \(files.count)/\(bundle.files.count) files (CloudKit field limit)")
        }

        for (index, file) in files.enumerated() {
            // Re-sending an unchanged audio file on every sidecar edit would
            // make each transcript or card update cost the whole recording.
            if let existing,
               existing["asset\(index)RelativePath"] as? String == file.descriptor.relativePath,
               Self.isUnchanged(file.descriptor, comparedTo: previousFiles) {
                continue
            }
            record["asset\(index)"] = CKAsset(fileURL: file.url)
            record["asset\(index)Role"] = file.descriptor.role.rawValue as CKRecordValue
            record["asset\(index)Name"] = file.descriptor.fileName as CKRecordValue
            record["asset\(index)RelativePath"] = file.descriptor.relativePath as CKRecordValue
        }

        let saved = try await save(record)
        return saved.recordChangeTag
    }

    static func isUnchanged(_ file: RecordingBundleFile, comparedTo previous: [RecordingBundleFile]) -> Bool {
        guard file.role != .metadata,
              let old = previous.first(where: { $0.relativePath == file.relativePath }) else {
            return false
        }
        return old.byteSize == file.byteSize
            && old.modifiedAt.timeIntervalSince1970.rounded(.down) == file.modifiedAt.timeIntervalSince1970.rounded(.down)
    }

    static let subscriptionID = "recording-bundle-changes"

    /// Records live in the default zone, where only query subscriptions work.
    public func ensureChangeSubscription() async throws {
        do {
            _ = try await database.subscription(for: Self.subscriptionID)
            return
        } catch let error as CKError where error.code == .unknownItem {
            // not registered yet
        }
        let subscription = CKQuerySubscription(
            recordType: "RecordingBundle",
            predicate: NSPredicate(value: true),
            subscriptionID: Self.subscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
        log("[CloudSync] push subscription registered")
    }

    static var bookkeepingKeys: [CKRecord.FieldKey] {
        ["manifestJSON", "assetCount"] + (0..<maxAssetsPerRecord).map { "asset\($0)RelativePath" }
    }

    static func manifest(of record: CKRecord) -> RecordingBundleManifest? {
        guard let json = record["manifestJSON"] as? String, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.wimmSyncDecoder.decode(RecordingBundleManifest.self, from: data)
    }

    /// 50 assets × 4 fields plus the scalar fields stays safely under
    /// CloudKit's 256-fields-per-record-type limit.
    static let maxAssetsPerRecord = 50

    static func prioritizedFiles(_ files: [LocalRecordingBundleFile], limit: Int) -> [LocalRecordingBundleFile] {
        guard files.count > limit else { return files }
        let rank: [RecordingBundleFileRole: Int] = [
            .primary: 0, .metadata: 1, .mini: 2, .screenshot: 3, .attachment: 4, .other: 5,
        ]
        let sorted = files.enumerated().sorted { lhs, rhs in
            let lr = rank[lhs.element.descriptor.role] ?? 5
            let rr = rank[rhs.element.descriptor.role] ?? 5
            return lr != rr ? lr < rr : lhs.offset < rhs.offset
        }
        return sorted.prefix(limit).map(\.element)
    }

    /// Lists what the cloud holds without downloading any asset. `updatedAt`
    /// is the uploading device's file time, not the server's save time, so a
    /// lower bound only narrows the scan — callers must pick it with that
    /// slack in mind. Paged with a cursor: the one-shot `perform(_:)` returned
    /// only the first batch, and everything past it was silently skipped.
    public func fetchChangeSummaries(since: Date?) async throws -> [RemoteRecordingSummary] {
        let lowerBound = since ?? Date.distantPast
        let predicate = NSPredicate(format: "updatedAt > %@", lowerBound as NSDate)
        let query = CKQuery(recordType: "RecordingBundle", predicate: predicate)
        let records = try await performAllPages(
            query,
            desiredKeys: ["syncId", "updatedAt", "isDeleted", "prefix"]
        )
        return records.compactMap { record in
            guard let updatedAt = record["updatedAt"] as? Date else { return nil }
            let rawID = record["syncId"] as? String ?? record.recordID.recordName
            return RemoteRecordingSummary(
                syncId: SyncRecordingID(rawValue: rawID),
                updatedAt: updatedAt,
                isDeleted: (record["isDeleted"] as? Int ?? 0) != 0,
                filenamePrefix: record["prefix"] as? String ?? ""
            )
        }
    }

    public func fetchBundle(
        syncId: SyncRecordingID,
        skipping: @Sendable (RecordingBundleManifest, RecordingBundleFile) -> Bool
    ) async throws -> RemoteRecordingBundle {
        let recordID = CKRecord.ID(recordName: syncId.rawValue)
        // Look before downloading: a changed sidecar should not pull the whole
        // recording again when this device already holds the same audio.
        let head = try await fetch(recordID, desiredKeys: Self.bookkeepingKeys)
        guard let manifest = Self.manifest(of: head) else {
            throw RecordingSyncError.invalidCloudPayload("missing manifestJSON")
        }
        let count = head["assetCount"] as? Int ?? 0
        var keys: [CKRecord.FieldKey] = ["manifestJSON", "assetCount"]
        for index in 0..<count {
            let path = head["asset\(index)RelativePath"] as? String
            if let path,
               let descriptor = manifest.files.first(where: { $0.relativePath == path }),
               skipping(manifest, descriptor) {
                continue
            }
            keys += ["asset\(index)", "asset\(index)Role", "asset\(index)Name", "asset\(index)RelativePath"]
        }
        return try decodeRemoteBundle(from: try await fetch(recordID, desiredKeys: keys))
    }

    public func markDeleted(syncId: SyncRecordingID, updatedAt: Date) async throws {
        let recordID = CKRecord.ID(recordName: syncId.rawValue)
        let record = (try? await fetch(recordID, desiredKeys: Self.bookkeepingKeys)) ?? CKRecord(recordType: "RecordingBundle", recordID: recordID)
        record["syncId"] = syncId.rawValue as CKRecordValue
        record["updatedAt"] = updatedAt as NSDate
        record["isDeleted"] = true as CKRecordValue
        record["schemaVersion"] = 1 as CKRecordValue
        _ = try await save(record)
    }

    private func fetch(_ recordID: CKRecord.ID, desiredKeys: [CKRecord.FieldKey]) async throws -> CKRecord {
        let results = try await database.records(for: [recordID], desiredKeys: desiredKeys)
        guard let result = results[recordID] else {
            throw RecordingSyncError.invalidCloudPayload("fetch returned no record")
        }
        return try result.get()
    }

    private func fetch(_ recordID: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(throwing: RecordingSyncError.invalidCloudPayload("fetch returned no record"))
                }
            }
        }
    }

    private func save(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.save(record) { saved, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let saved {
                    continuation.resume(returning: saved)
                } else {
                    continuation.resume(throwing: RecordingSyncError.invalidCloudPayload("save returned no record"))
                }
            }
        }
    }

    private func performAllPages(_ query: CKQuery, desiredKeys: [CKRecord.FieldKey]) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var page = try await database.records(
            matching: query,
            inZoneWith: nil,
            desiredKeys: desiredKeys,
            resultsLimit: CKQueryOperation.maximumResults
        )
        while true {
            for (_, result) in page.matchResults {
                records.append(try result.get())
            }
            guard let cursor = page.queryCursor else { return records }
            page = try await database.records(
                continuingMatchFrom: cursor,
                desiredKeys: desiredKeys,
                resultsLimit: CKQueryOperation.maximumResults
            )
        }
    }

    private func decodeRemoteBundle(from record: CKRecord) throws -> RemoteRecordingBundle {
        guard let manifestJSON = record["manifestJSON"] as? String,
              let data = manifestJSON.data(using: .utf8) else {
            throw RecordingSyncError.invalidCloudPayload("missing manifestJSON")
        }
        let manifest = try JSONDecoder.wimmSyncDecoder.decode(RecordingBundleManifest.self, from: data)
        let count = record["assetCount"] as? Int ?? 0
        var files: [RemoteRecordingBundleFile] = []
        files.reserveCapacity(count)

        for index in 0..<count {
            guard let asset = record["asset\(index)"] as? CKAsset,
                  let fileURL = asset.fileURL else { continue }
            let fileData = try Data(contentsOf: fileURL)
            let descriptor = manifest.files.first {
                $0.relativePath == (record["asset\(index)RelativePath"] as? String)
            } ?? RecordingBundleFile(
                role: RecordingBundleFileRole(rawValue: record["asset\(index)Role"] as? String ?? "") ?? .other,
                relativePath: record["asset\(index)RelativePath"] as? String ?? "Recordings/\(record["asset\(index)Name"] as? String ?? UUID().uuidString)",
                fileName: record["asset\(index)Name"] as? String ?? UUID().uuidString,
                byteSize: UInt64(fileData.count),
                modifiedAt: manifest.updatedAt
            )
            files.append(RemoteRecordingBundleFile(descriptor: descriptor, data: fileData))
        }

        return RemoteRecordingBundle(manifest: manifest, files: files)
    }
}
#endif
