import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// The wire and on-disk shapes of a synced recording bundle: its id, its
// files and their roles, the manifest that travels with it, and the errors
// the sync path can raise.

public struct SyncRecordingID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ uuid: UUID = UUID()) {
        self.rawValue = uuid.uuidString
    }

    public var description: String { rawValue }
}

public enum RecordingBundleFileRole: String, Codable, Sendable {
    case primary
    case metadata
    case attachment
    case screenshot
    case mini
    case other
}

public struct RecordingBundleFile: Codable, Hashable, Sendable {
    public let role: RecordingBundleFileRole
    public let relativePath: String
    public let fileName: String
    public let byteSize: UInt64
    public let modifiedAt: Date

    public init(role: RecordingBundleFileRole, relativePath: String, fileName: String, byteSize: UInt64, modifiedAt: Date) {
        self.role = role
        self.relativePath = relativePath
        self.fileName = fileName
        self.byteSize = byteSize
        self.modifiedAt = modifiedAt
    }
}

public struct RecordingBundleManifest: Codable, Hashable, Sendable {
    public let syncId: SyncRecordingID
    public let filenamePrefix: String
    public let createdAt: Date
    public let updatedAt: Date
    public let originDeviceId: String
    public let schemaVersion: Int
    public let files: [RecordingBundleFile]
    public let isDeleted: Bool

    public init(
        syncId: SyncRecordingID,
        filenamePrefix: String,
        createdAt: Date,
        updatedAt: Date,
        originDeviceId: String,
        schemaVersion: Int = 1,
        files: [RecordingBundleFile],
        isDeleted: Bool = false
    ) {
        self.syncId = syncId
        self.filenamePrefix = filenamePrefix
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceId = originDeviceId
        self.schemaVersion = schemaVersion
        self.files = files
        self.isDeleted = isDeleted
    }
}

public struct LocalRecordingBundleFile: Sendable {
    public let descriptor: RecordingBundleFile
    public let url: URL

    public init(descriptor: RecordingBundleFile, url: URL) {
        self.descriptor = descriptor
        self.url = url
    }
}

public struct LocalRecordingBundle: Sendable {
    public let manifest: RecordingBundleManifest
    public let files: [LocalRecordingBundleFile]

    public init(manifest: RecordingBundleManifest, files: [LocalRecordingBundleFile]) {
        self.manifest = manifest
        self.files = files
    }
}

public struct RemoteRecordingBundleFile: Sendable {
    public let descriptor: RecordingBundleFile
    public let data: Data

    public init(descriptor: RecordingBundleFile, data: Data) {
        self.descriptor = descriptor
        self.data = data
    }
}

public struct RemoteRecordingBundle: Sendable {
    public let manifest: RecordingBundleManifest
    public let files: [RemoteRecordingBundleFile]

    public init(manifest: RecordingBundleManifest, files: [RemoteRecordingBundleFile]) {
        self.manifest = manifest
        self.files = files
    }
}

/// One cloud record as listed for reconciliation — identity and version only,
/// so a scan of the whole library costs no asset downloads.
public struct RemoteRecordingSummary: Sendable, Hashable {
    public let syncId: SyncRecordingID
    public let updatedAt: Date
    public let isDeleted: Bool
    public let filenamePrefix: String

    public init(syncId: SyncRecordingID, updatedAt: Date, isDeleted: Bool, filenamePrefix: String = "") {
        self.syncId = syncId
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.filenamePrefix = filenamePrefix
    }
}

public enum RecordingSyncError: Error, LocalizedError, Sendable {
    case unsupportedRecording(URL)
    case missingPrimaryFile(URL)
    case missingSyncId(URL)
    case cloudKitUnavailable
    case invalidCloudPayload(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRecording(let url):
            return "Unsupported recording file: \(url.lastPathComponent)"
        case .missingPrimaryFile(let url):
            return "Missing primary file: \(url.path)"
        case .missingSyncId(let url):
            return "Missing syncId in metadata: \(url.lastPathComponent)"
        case .cloudKitUnavailable:
            return "CloudKit is unavailable on this platform."
        case .invalidCloudPayload(let reason):
            return "Invalid CloudKit payload: \(reason)"
        }
    }
}
