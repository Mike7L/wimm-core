import CryptoKit
import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif

// The personal document travels to the phone as one read-only snapshot
// (docs/Vision_Document_iPhone_Mac_2026-11-02.md, step 1). The Mac is the only
// writer: it publishes the file whenever its content changes, and the iPhone
// keeps the latest copy in its library. Nothing is ever written back.

/// What the cloud says about the published copy; the text travels separately.
public struct PersonalDocumentSnapshotInfo: Codable, Equatable, Sendable {
    public static let kind = "personalDocument"

    public var kind: String = Self.kind
    public var version: Int = 1
    public let sha256: String
    public let byteCount: Int
    public let fileName: String
    public let publishedAt: Date
    public let originDeviceId: String

    public init(sha256: String, byteCount: Int, fileName: String, publishedAt: Date, originDeviceId: String) {
        self.sha256 = sha256
        self.byteCount = byteCount
        self.fileName = fileName
        self.publishedAt = publishedAt
        self.originDeviceId = originDeviceId
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol PersonalDocumentSnapshotTransport: Sendable {
    func publish(_ info: PersonalDocumentSnapshotInfo, text: Data) async throws
    /// nil when nothing was published yet.
    func fetchInfo() async throws -> PersonalDocumentSnapshotInfo?
    func fetchSnapshot() async throws -> (PersonalDocumentSnapshotInfo, Data)?
}

/// `<library>/PersonalDocument/`: the reader's copy (`snapshot.md` + `.json`)
/// and the publisher's record of what it last sent (`published.json`).
public struct PersonalDocumentSnapshotCache: Sendable {
    public let directory: URL

    public init(directory: URL = StoragePaths.baseDirectory().appendingPathComponent("PersonalDocument", isDirectory: true)) {
        self.directory = directory
    }

    private var textURL: URL { directory.appendingPathComponent("snapshot.md") }
    private var infoURL: URL { directory.appendingPathComponent("snapshot.json") }
    private var publishedURL: URL { directory.appendingPathComponent("published.json") }

    public func load() -> (info: PersonalDocumentSnapshotInfo, text: String)? {
        guard let info = Self.read(infoURL),
              let data = try? Data(contentsOf: textURL),
              PersonalDocumentSnapshotInfo.digest(data) == info.sha256,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (info, text)
    }

    public var info: PersonalDocumentSnapshotInfo? { Self.read(infoURL) }

    /// Text first, info last: a reader that sees the new info finds the new text.
    func store(_ info: PersonalDocumentSnapshotInfo, text: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: textURL, options: .atomic)
        try JSONEncoder.wimmSyncEncoder.encode(info).write(to: infoURL, options: .atomic)
    }

    var published: PersonalDocumentSnapshotInfo? { Self.read(publishedURL) }

    func recordPublished(_ info: PersonalDocumentSnapshotInfo) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder.wimmSyncEncoder.encode(info).write(to: publishedURL, options: .atomic)
    }

    private static func read(_ url: URL) -> PersonalDocumentSnapshotInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.wimmSyncDecoder.decode(PersonalDocumentSnapshotInfo.self, from: data)
    }
}

public actor PersonalDocumentSync {
    public enum Role: Sendable {
        /// Publishes the file the closure names (nil: no document chosen).
        case publisher(source: @Sendable () -> URL?)
        case reader
    }

    private let transport: any PersonalDocumentSnapshotTransport
    private let role: Role
    public nonisolated let cache: PersonalDocumentSnapshotCache
    private let deviceID: String
    private let now: @Sendable () -> Date

    public init(
        transport: any PersonalDocumentSnapshotTransport,
        role: Role,
        cache: PersonalDocumentSnapshotCache = PersonalDocumentSnapshotCache(),
        deviceID: String = RecordingSyncDeviceIdentity.currentDeviceID(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.role = role
        self.cache = cache
        self.deviceID = deviceID
        self.now = now
    }

    /// Runs with every recording sync; a failure only waits for the next one.
    public func syncNow() async {
        do {
            switch role {
            case .publisher: _ = try await publishIfChanged()
            case .reader: _ = try await refresh()
            }
        } catch {
            log("[DocumentSync] \(error)")
        }
    }

    /// Returns whether a new copy went up. Unchanged text costs one file read.
    @discardableResult
    public func publishIfChanged() async throws -> Bool {
        guard case .publisher(let source) = role, let url = source() else { return false }
        let data = try Self.coordinatedRead(url)
        let sha = PersonalDocumentSnapshotInfo.digest(data)
        if cache.published?.sha256 == sha { return false }
        // First run on this Mac, or the published record was lost: ask the
        // cloud before sending 400 KB it may already hold.
        if let remote = try await transport.fetchInfo(), remote.sha256 == sha {
            try cache.recordPublished(remote)
            return false
        }
        let info = PersonalDocumentSnapshotInfo(
            sha256: sha, byteCount: data.count, fileName: url.lastPathComponent,
            publishedAt: now(), originDeviceId: deviceID
        )
        try await transport.publish(info, text: data)
        try cache.recordPublished(info)
        log("[DocumentSync] published \(url.lastPathComponent) (\(data.count) bytes)")
        return true
    }

    /// Returns whether the local copy changed. Unchanged costs one small fetch.
    @discardableResult
    public func refresh() async throws -> Bool {
        guard let remote = try await transport.fetchInfo() else { return false }
        if cache.info?.sha256 == remote.sha256, cache.load() != nil { return false }
        guard let (info, data) = try await transport.fetchSnapshot() else { return false }
        guard PersonalDocumentSnapshotInfo.digest(data) == info.sha256 else {
            throw RecordingSyncError.invalidCloudPayload("personal document hash mismatch")
        }
        try cache.store(info, text: data)
        return true
    }

    static func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // MARK: - Live

    /// One per app, built by `CloudRecordingSyncService.live()` beside the
    /// recording sync. The Mac publishes, every other platform reads.
    public static func live() -> PersonalDocumentSync? { CloudRecordingSyncService.live()?.documentSync }

    static func makeLive(containerIdentifier: String) -> PersonalDocumentSync? {
        #if canImport(CloudKit)
        let transport = CloudKitPersonalDocumentTransport(containerIdentifier: containerIdentifier)
        #if os(macOS)
        return PersonalDocumentSync(transport: transport, role: .publisher(source: { PersonalDocumentLocation.current() }))
        #else
        return PersonalDocumentSync(transport: transport, role: .reader)
        #endif
        #else
        return nil
        #endif
    }
}

#if os(macOS)
/// The document the Mac apps have open. Wimm and Studio share one defaults
/// domain, so either app finds the other's choice; Studio's wins.
public enum PersonalDocumentLocation {
    public static let bookmarkKeys = ["WimmStudio.documentBookmark", "PersonalDocument.fileBookmark"]

    public static func current(defaults: UserDefaults = .standard) -> URL? {
        guard !StoragePaths.isTestProcess else { return nil }
        for key in bookmarkKeys {
            guard let data = defaults.data(forKey: key) else { continue }
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        let conventional = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects/_ME/docs/me_structured.md")
        return FileManager.default.fileExists(atPath: conventional.path) ? conventional : nil
    }
}
#endif

#if canImport(CloudKit)
/// One record in the existing `RecordingBundle` type, under a fixed name.
/// Both clients are on the Production schema, which takes no new record
/// types or fields without a deploy from the CloudKit Console, so the
/// snapshot reuses fields that already exist there. It never sets
/// `updatedAt`: recording sync finds bundles only through
/// `updatedAt > …` queries (and drops a result without it), so old and new
/// builds alike never see this record as a note. Fetched only by its name.
final class CloudKitPersonalDocumentTransport: PersonalDocumentSnapshotTransport, @unchecked Sendable {
    static let recordID = CKRecord.ID(recordName: "wimm-personal-document")
    private let database: CKDatabase

    init(containerIdentifier: String) {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    func publish(_ info: PersonalDocumentSnapshotInfo, text: Data) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-personal-document-\(UUID().uuidString).md")
        try text.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }

        let record = CKRecord(recordType: "RecordingBundle", recordID: Self.recordID)
        record["prefix"] = "personal-document" as CKRecordValue
        record["createdAt"] = info.publishedAt as NSDate
        record["originDeviceId"] = info.originDeviceId as CKRecordValue
        record["schemaVersion"] = info.version as CKRecordValue
        let json = try JSONEncoder.wimmSyncEncoder.encode(info)
        record["manifestJSON"] = String(decoding: json, as: UTF8.self) as CKRecordValue
        record["asset0"] = CKAsset(fileURL: file)
        record["asset0Name"] = info.fileName as CKRecordValue
        // .changedKeys: one writer, so no change-tag round trip is needed.
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .changedKeys)
        _ = try results[Self.recordID]?.get()
    }

    func fetchInfo() async throws -> PersonalDocumentSnapshotInfo? {
        guard let record = try await fetch(keys: ["manifestJSON"]) else { return nil }
        return try Self.info(of: record)
    }

    func fetchSnapshot() async throws -> (PersonalDocumentSnapshotInfo, Data)? {
        guard let record = try await fetch(keys: ["manifestJSON", "asset0"]) else { return nil }
        guard let asset = record["asset0"] as? CKAsset, let url = asset.fileURL else {
            throw RecordingSyncError.invalidCloudPayload("personal document without text")
        }
        return (try Self.info(of: record), try Data(contentsOf: url))
    }

    private func fetch(keys: [CKRecord.FieldKey]) async throws -> CKRecord? {
        do {
            let results = try await database.records(for: [Self.recordID], desiredKeys: keys)
            return try results[Self.recordID]?.get()
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private static func info(of record: CKRecord) throws -> PersonalDocumentSnapshotInfo {
        guard let json = record["manifestJSON"] as? String,
              let info = try? JSONDecoder.wimmSyncDecoder.decode(PersonalDocumentSnapshotInfo.self, from: Data(json.utf8)),
              info.kind == PersonalDocumentSnapshotInfo.kind else {
            throw RecordingSyncError.invalidCloudPayload("personal document record without its info")
        }
        return info
    }
}
#endif
