import Foundation
import WimmDomain
#if canImport(CloudKit)
import CloudKit
#endif
#if os(macOS) && canImport(Security)
import Security
#endif

// Collecting the files that belong to one recording into an uploadable
// bundle.

public struct RecordingBundleBuilder: Sendable {
    public var originDeviceId: String

    public init(originDeviceId: String = RecordingSyncDeviceIdentity.currentDeviceID()) {
        self.originDeviceId = originDeviceId
    }

    public func build(for recordingURL: URL, assignSyncID: Bool, directorySnapshot: RecordingBundleDirectorySnapshot? = nil) throws -> LocalRecordingBundle {
        guard FileManager.default.fileExists(atPath: recordingURL.path) else {
            throw RecordingSyncError.missingPrimaryFile(recordingURL)
        }
        guard isPrimaryRecording(recordingURL) else {
            throw RecordingSyncError.unsupportedRecording(recordingURL)
        }

        let syncId: SyncRecordingID
        if let existing = RecordingSyncMetadata.readSyncID(for: recordingURL) {
            // Building an already-identified bundle is read-only. Re-stamping
            // the sidecar here invalidated the batch listing and local version.
            syncId = existing
        } else if assignSyncID {
            syncId = try RecordingSyncMetadata.ensureSyncID(for: recordingURL)
        } else {
            throw RecordingSyncError.missingSyncId(recordingURL)
        }

        let prefix = recordingURL.deletingPathExtension().lastPathComponent
        let snapshot = directorySnapshot ?? RecordingBundleDirectorySnapshot()
        let files = try snapshot.withCurrentIndex(in: recordingURL.deletingLastPathComponent()) { index in
            let files = try collectBundleURLs(for: recordingURL, directoryIndex: index).map { url, role in
                try makeFile(url: url, role: role)
            }
            guard files.contains(where: { $0.descriptor.role == .primary }) else {
                throw RecordingSyncError.missingPrimaryFile(recordingURL)
            }
            return files
        }
        let descriptors = files.map(\.descriptor)
        let createdAt = FileStore.recordingDateFromFileName(recordingURL) ?? ((try? FileStore.fileCreationDate(recordingURL)) ?? Date())
        let updatedAt = descriptors.map(\.modifiedAt).max() ?? FileStore.fileModificationDate(recordingURL)

        return LocalRecordingBundle(
            manifest: RecordingBundleManifest(
                syncId: syncId,
                filenamePrefix: prefix,
                createdAt: createdAt,
                updatedAt: updatedAt,
                originDeviceId: originDeviceId,
                files: descriptors
            ),
            files: files
        )
    }

    public func inspect(for recordingURL: URL, directorySnapshot: RecordingBundleDirectorySnapshot? = nil) -> RecordingBackfillCandidate {
        guard isPrimaryRecording(recordingURL), FileManager.default.fileExists(atPath: recordingURL.path) else {
            return RecordingBackfillCandidate(recordingURL: recordingURL, hasSyncId: false, fileCount: 0, totalBytes: 0, error: "unsupported or missing primary file")
        }
        let snapshot = directorySnapshot ?? RecordingBundleDirectorySnapshot()
        do {
            return try snapshot.withCurrentIndex(in: recordingURL.deletingLastPathComponent()) { index in
                let urls = collectBundleURLs(for: recordingURL, directoryIndex: index)
                return RecordingBackfillCandidate(
                    recordingURL: recordingURL,
                    hasSyncId: RecordingSyncMetadata.readSyncID(for: recordingURL) != nil,
                    fileCount: urls.count,
                    totalBytes: urls.reduce(UInt64(0)) { $0 + fileSize($1.url) },
                    error: nil
                )
            }
        } catch {
            return RecordingBackfillCandidate(recordingURL: recordingURL, hasSyncId: false, fileCount: 0, totalBytes: 0, error: error.localizedDescription)
        }
    }

    private func isPrimaryRecording(_ url: URL) -> Bool {
        guard FileStore.isSupportedRecordingFile(url) else { return false }
        return !FileStore.isDerivedAudioFile(url) && !FileStore.isAttachmentFile(url)
    }

    private func collectBundleURLs(for recordingURL: URL, directoryIndex: RecordingsDirectoryIndex) -> [(url: URL, role: RecordingBundleFileRole)] {
        var seen = Set<String>()
        var result: [(URL, RecordingBundleFileRole)] = []

        func append(_ url: URL, role: RecordingBundleFileRole) {
            let resolved = url.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path) else { return }
            guard seen.insert(resolved.path).inserted else { return }
            result.append((resolved, role))
        }

        append(recordingURL, role: .primary)
        append(FileStore.metadataURL(forRecordingURL: recordingURL), role: .metadata)
        // Derived audio (_micro; formerly _mini) is intentionally NOT bundled: it is
        // regenerated locally on demand, and syncing it doubled audio bytes per bundle.
        // The `.mini` role stays in the enum so legacy bundles still decode.
        append(FileStore.legacyPNGScreenshotURL(forRecordingURL: recordingURL), role: .screenshot)
        for screenshot in directoryIndex.allScreenshotURLs(forRecordingURL: recordingURL) {
            append(screenshot, role: .screenshot)
        }
        for attachment in attachmentURLs(for: recordingURL, directoryIndex: directoryIndex) {
            append(attachment, role: .attachment)
        }

        return result
    }

    private func attachmentURLs(for recordingURL: URL, directoryIndex: RecordingsDirectoryIndex) -> [URL] {
        let metaURL = FileStore.metadataURL(forRecordingURL: recordingURL)
        var urls: [URL] = []
        if let data = try? Data(contentsOf: metaURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let attachments = json["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                guard let raw = attachment["url"] as? String else { continue }
                let resolved: URL
                if raw.contains("://"), let url = URL(string: raw) {
                    resolved = url.isFileURL ? url : FileStore.resolveRelativePath(raw)
                } else {
                    resolved = FileStore.resolveRelativePath(raw)
                }
                urls.append(resolved)
            }
        }

        urls.append(contentsOf: directoryIndex.attachmentURLs(forRecordingURL: recordingURL))
        return urls
    }

    private func makeFile(url: URL, role: RecordingBundleFileRole) throws -> LocalRecordingBundleFile {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attrs[.modificationDate] as? Date) ?? Date()
        let descriptor = RecordingBundleFile(
            role: role,
            relativePath: FileStore.relativePath(for: url),
            fileName: url.lastPathComponent,
            byteSize: size,
            modifiedAt: modified
        )
        return LocalRecordingBundleFile(descriptor: descriptor, url: url)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
