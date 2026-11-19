import CryptoKit
import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif

// The iPhone's event logs travel to the Mac for analysis. The phone uploads
// its recent `events_*.jsonl` files (compressed) to the private iCloud
// database; the Mac copies them into `<library>/logs/devices/<device>/`.
// Logs are already masked by `UnifiedEventLogger`. Nothing goes up while
// private mode is on.

/// One uploaded log file as the cloud lists it.
public struct DeviceLogFile: Codable, Equatable, Sendable {
    /// `events_2026-11-19.jsonl` (or a rotated `events_2026-11-19.1.jsonl`).
    public let name: String
    /// Of the uncompressed file.
    public let sha256: String
    public let byteCount: Int
    public let uploadedAt: Date

    public init(name: String, sha256: String, byteCount: Int, uploadedAt: Date) {
        self.name = name
        self.sha256 = sha256
        self.byteCount = byteCount
        self.uploadedAt = uploadedAt
    }
}

/// What one device has in the cloud right now.
public struct DeviceLogIndex: Codable, Equatable, Sendable {
    public static let kind = "deviceLogIndex"

    public var kind: String = Self.kind
    public var version: Int = 1
    public let deviceID: String
    /// Hardware model and a short id, e.g. `iPhone17,1-3F2A9C1B`; names the Mac folder.
    public let deviceLabel: String
    public var files: [DeviceLogFile]

    public init(deviceID: String, deviceLabel: String, files: [DeviceLogFile]) {
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
        self.files = files
    }
}

public protocol DeviceLogTransport: Sendable {
    /// Device ids that ever published logs.
    func fetchDevices() async throws -> [String]
    /// Adds the id to the shared device list (several devices may write it).
    func registerDevice(_ deviceID: String) async throws
    func fetchIndex(deviceID: String) async throws -> DeviceLogIndex?
    func publishIndex(_ index: DeviceLogIndex) async throws
    /// `data` is already compressed.
    func uploadFile(deviceID: String, name: String, data: Data) async throws
    func downloadFile(deviceID: String, name: String) async throws -> Data?
    func deleteFiles(deviceID: String, names: [String]) async throws
}

public actor DeviceLogSync {
    public enum Role: Sendable {
        /// The iPhone: sends its own logs.
        case uploader
        /// The Mac: collects every other device's logs.
        case collector
    }

    private let transport: any DeviceLogTransport
    private let role: Role
    private let eventsDirectory: URL
    private let stateDirectory: URL
    /// The Mac's copies: `<collectDirectory>/<deviceLabel>/<file>`.
    private let collectDirectory: URL
    private let deviceID: String
    private let deviceLabel: String
    private let now: @Sendable () -> Date
    private let privateMode: @Sendable () -> Bool
    /// Upload today's and the previous days' files; older ones leave the cloud.
    private let uploadDays: Int
    private let keepDays: Int
    private let minInterval: TimeInterval
    private var lastRun: Date?

    public init(
        transport: any DeviceLogTransport,
        role: Role,
        eventsDirectory: URL = UnifiedEventLogger.eventsDirectoryURL(),
        stateDirectory: URL = StoragePaths.baseDirectory().appendingPathComponent("sync", isDirectory: true),
        collectDirectory: URL = DeviceLogSync.defaultCollectDirectory(),
        deviceID: String = RecordingSyncDeviceIdentity.currentDeviceID(),
        deviceLabel: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        privateMode: @escaping @Sendable () -> Bool = { PrivateMode.isEnabled },
        uploadDays: Int = 3,
        keepDays: Int = 14,
        minInterval: TimeInterval = 30 * 60
    ) {
        self.transport = transport
        self.role = role
        self.eventsDirectory = eventsDirectory
        self.stateDirectory = stateDirectory
        self.collectDirectory = collectDirectory
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel ?? Self.defaultLabel(deviceID: deviceID)
        self.now = now
        self.privateMode = privateMode
        self.uploadDays = max(1, uploadDays)
        self.keepDays = max(uploadDays, keepDays)
        self.minInterval = minInterval
    }

    public static func defaultCollectDirectory() -> URL {
        StoragePaths.baseDirectory()
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("devices", isDirectory: true)
    }

    /// Runs with every recording sync, at most once per `minInterval`;
    /// a failure only waits for the next one.
    public func syncNow(force: Bool = false) async {
        let started = now()
        if !force, let lastRun, started.timeIntervalSince(lastRun) < minInterval { return }
        lastRun = started
        do {
            switch role {
            case .uploader: _ = try await upload()
            case .collector: _ = try await collect()
            }
        } catch {
            log("[DeviceLogSync] \(error)")
        }
    }

    // MARK: - Uploader

    /// Returns the names of the files sent this time.
    @discardableResult
    public func upload() async throws -> [String] {
        guard !privateMode() else { return [] }
        var index = loadPublished() ?? DeviceLogIndex(deviceID: deviceID, deviceLabel: deviceLabel, files: [])
        if index.files.isEmpty {
            // First run on this device, or the local record was lost.
            if let remote = try await transport.fetchIndex(deviceID: deviceID) { index = remote }
        }
        let known = Dictionary(index.files.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now())
        let uploadFrom = calendar.date(byAdding: .day, value: -(uploadDays - 1), to: today) ?? today
        let keepFrom = calendar.date(byAdding: .day, value: -(keepDays - 1), to: today) ?? today

        var sent: [String] = []
        for file in localFiles() {
            guard let day = Self.day(ofFileName: file.lastPathComponent), day >= uploadFrom else { continue }
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { continue }
            let sha = Self.digest(data)
            let name = file.lastPathComponent
            if known[name]?.sha256 == sha { continue }
            try await transport.uploadFile(deviceID: deviceID, name: name, data: try Self.compress(data))
            index.files.removeAll { $0.name == name }
            index.files.append(DeviceLogFile(name: name, sha256: sha, byteCount: data.count, uploadedAt: now()))
            sent.append(name)
        }

        let expired = index.files.filter { file in
            guard let day = Self.day(ofFileName: file.name) else { return true }
            return day < keepFrom
        }.map(\.name)
        if !expired.isEmpty {
            try await transport.deleteFiles(deviceID: deviceID, names: expired)
            index.files.removeAll { expired.contains($0.name) }
        }

        guard !sent.isEmpty || !expired.isEmpty || loadPublished() == nil else { return [] }
        index.files.sort { $0.name < $1.name }
        try await transport.publishIndex(index)
        if loadPublished() == nil {
            try await transport.registerDevice(deviceID)
        }
        try savePublished(index)
        if !sent.isEmpty { log("[DeviceLogSync] uploaded \(sent.joined(separator: ", "))") }
        return sent
    }

    private func localFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: eventsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { Self.day(ofFileName: $0.lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private var publishedURL: URL { stateDirectory.appendingPathComponent("device_logs_published.json") }

    private func loadPublished() -> DeviceLogIndex? {
        guard let data = try? Data(contentsOf: publishedURL) else { return nil }
        return try? JSONDecoder.wimmSyncDecoder.decode(DeviceLogIndex.self, from: data)
    }

    private func savePublished(_ index: DeviceLogIndex) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONEncoder.wimmSyncEncoder.encode(index).write(to: publishedURL, options: .atomic)
    }

    // MARK: - Collector

    /// Copies every changed file of every other device. Returns the local
    /// paths written this time. Files that left the cloud stay on the Mac.
    @discardableResult
    public func collect() async throws -> [URL] {
        var written: [URL] = []
        for id in try await transport.fetchDevices() where id != deviceID {
            guard let index = try await transport.fetchIndex(deviceID: id) else { continue }
            let folder = collectDirectory.appendingPathComponent(Self.safeFolderName(index.deviceLabel), isDirectory: true)
            for file in index.files {
                let target = folder.appendingPathComponent(Self.safeFolderName(file.name))
                if let local = try? Data(contentsOf: target), Self.digest(local) == file.sha256 { continue }
                guard let packed = try await transport.downloadFile(deviceID: id, name: file.name) else { continue }
                let data = try Self.decompress(packed)
                // The record may be newer than the index; keep whatever came.
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                written.append(target)
            }
        }
        if !written.isEmpty { log("[DeviceLogSync] collected \(written.count) log file(s)") }
        return written
    }

    // MARK: - Helpers

    static func day(ofFileName name: String) -> Date? {
        guard name.hasPrefix("events_"), name.hasSuffix(".jsonl") else { return nil }
        let stem = name.dropFirst("events_".count).prefix(10)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(stem))
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }

    static func safeFolderName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.,"))
        let cleaned = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "device" : trimmed
    }

    static func defaultLabel(deviceID: String) -> String {
        var info = utsname()
        uname(&info)
        let model = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(model.isEmpty ? "device" : model)-\(deviceID.prefix(8))"
    }

    // MARK: - Live

    /// iOS uploads, the Mac collects. Built by `CloudRecordingSyncService` beside the recording sync.
    static func makeLive(containerIdentifier: String) -> DeviceLogSync? {
        #if canImport(CloudKit)
        let transport = CloudKitDeviceLogTransport(containerIdentifier: containerIdentifier)
        #if os(macOS)
        return DeviceLogSync(transport: transport, role: .collector)
        #else
        return DeviceLogSync(transport: transport, role: .uploader)
        #endif
        #else
        return nil
        #endif
    }
}

#if canImport(CloudKit)
/// Records in the existing `RecordingBundle` type under fixed names, like the
/// personal document: the Production schema takes no new types or fields
/// without a Console deploy. They never set `updatedAt`, so recording sync
/// (which finds bundles only through `updatedAt > …` queries) never sees them.
/// - `wimm-logs-devices`: the device list (`manifestJSON` = `[String]`)
/// - `wimm-logs-index-<device>`: `DeviceLogIndex`
/// - `wimm-logs-file-<device>-<file name>`: one zlib-compressed file in `asset0`
final class CloudKitDeviceLogTransport: DeviceLogTransport, @unchecked Sendable {
    private static let devicesID = CKRecord.ID(recordName: "wimm-logs-devices")
    private let database: CKDatabase

    init(containerIdentifier: String) {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    private static func indexID(_ device: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "wimm-logs-index-\(device)")
    }

    private static func fileID(_ device: String, _ name: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "wimm-logs-file-\(device)-\(name)")
    }

    private func record(_ id: CKRecord.ID, keys: [CKRecord.FieldKey]?) async throws -> CKRecord? {
        do {
            let results = try await database.records(for: [id], desiredKeys: keys)
            return try results[id]?.get()
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func save(_ record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy = .changedKeys) async throws {
        let (results, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: policy)
        _ = try results[record.recordID]?.get()
    }

    private static func newRecord(_ id: CKRecord.ID, prefix: String, device: String, json: Data) -> CKRecord {
        let record = CKRecord(recordType: "RecordingBundle", recordID: id)
        record["prefix"] = prefix as CKRecordValue
        record["createdAt"] = Date() as NSDate
        record["originDeviceId"] = device as CKRecordValue
        record["schemaVersion"] = 1 as CKRecordValue
        record["manifestJSON"] = String(decoding: json, as: UTF8.self) as CKRecordValue
        return record
    }

    func fetchDevices() async throws -> [String] {
        guard let record = try await record(Self.devicesID, keys: ["manifestJSON"]),
              let json = record["manifestJSON"] as? String else { return [] }
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    func registerDevice(_ deviceID: String) async throws {
        // Several devices may write the list: merge onto the server copy and
        // let CloudKit refuse a stale one, then try again.
        for attempt in 0..<3 {
            let existing = try await record(Self.devicesID, keys: nil)
            var devices: [String] = []
            if let json = existing?["manifestJSON"] as? String {
                devices = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
            }
            if devices.contains(deviceID) { return }
            devices.append(deviceID)
            let json = try JSONEncoder().encode(devices)
            let record = existing ?? Self.newRecord(Self.devicesID, prefix: "device-logs", device: deviceID, json: json)
            record["manifestJSON"] = String(decoding: json, as: UTF8.self) as CKRecordValue
            do {
                try await save(record, policy: .ifServerRecordUnchanged)
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 2 {
                continue
            }
        }
    }

    func fetchIndex(deviceID: String) async throws -> DeviceLogIndex? {
        guard let record = try await record(Self.indexID(deviceID), keys: ["manifestJSON"]),
              let json = record["manifestJSON"] as? String,
              let index = try? JSONDecoder.wimmSyncDecoder.decode(DeviceLogIndex.self, from: Data(json.utf8)),
              index.kind == DeviceLogIndex.kind else { return nil }
        return index
    }

    func publishIndex(_ index: DeviceLogIndex) async throws {
        let json = try JSONEncoder.wimmSyncEncoder.encode(index)
        // One writer per index, so no change-tag round trip.
        try await save(Self.newRecord(Self.indexID(index.deviceID), prefix: "device-logs", device: index.deviceID, json: json))
    }

    func uploadFile(deviceID: String, name: String, data: Data) async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-device-log-\(UUID().uuidString).zlib")
        try data.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let record = Self.newRecord(Self.fileID(deviceID, name), prefix: "device-logs", device: deviceID, json: Data("{}".utf8))
        record["asset0"] = CKAsset(fileURL: file)
        record["asset0Name"] = name as CKRecordValue
        try await save(record)
    }

    func downloadFile(deviceID: String, name: String) async throws -> Data? {
        guard let record = try await record(Self.fileID(deviceID, name), keys: ["asset0"]),
              let asset = record["asset0"] as? CKAsset, let url = asset.fileURL else { return nil }
        return try Data(contentsOf: url)
    }

    func deleteFiles(deviceID: String, names: [String]) async throws {
        guard !names.isEmpty else { return }
        let ids = names.map { Self.fileID(deviceID, $0) }
        let (_, results) = try await database.modifyRecords(saving: [], deleting: ids)
        for (_, result) in results {
            if case .failure(let error as CKError) = result, error.code == .unknownItem { continue }
            _ = try result.get()
        }
    }
}
#endif
