import Foundation

/// Moving a note's files to and from `Trash/`. Every delete path (Wimm, iOS, a
/// tombstone from another device) goes through here, so the trash marker below
/// is written in one place: the file sitting in Trash is the deletion, the
/// marker only records when and from where.
public enum RecordingTrashSupport {
    /// Sidecar keys of the trash marker, present only on the copy in `Trash/`.
    public static let markerKeys = ["trashed", "trashedAt", "originalPath"]

    @discardableResult
    public static func moveToTrash(
        file: URL,
        fileManager: FileManager = .default,
        didMoveMain: ((URL) -> Void)? = nil,
        onFailure: ((URL, Error) -> Void)? = nil
    ) -> URL? {
        let trashDir = FileStore.trashDirectory()
        try? fileManager.createDirectory(at: trashDir, withIntermediateDirectories: true)

        let fileName = file.lastPathComponent
        let relatedFiles = collectRelatedFiles(for: file, fileManager: fileManager)

        var movedFiles: [URL] = []
        var movedFilesBySource: [URL: URL] = [:]
        var success = true

        for sourceURL in relatedFiles {
            let destinationURL = trashDir.appendingPathComponent(sourceURL.lastPathComponent)

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }

                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedFiles.append(destinationURL)
                movedFilesBySource[sourceURL] = destinationURL
            } catch {
                onFailure?(sourceURL, error)
                success = false
                break
            }
        }

        if !success {
            for movedURL in movedFiles {
                let originalURL = file.deletingLastPathComponent().appendingPathComponent(movedURL.lastPathComponent)
                try? fileManager.moveItem(at: movedURL, to: originalURL)
            }
            return nil
        }

        guard let mainDestination = movedFiles.first(where: { $0.lastPathComponent == fileName }) else {
            return nil
        }

        rewriteAttachmentURLs(inMetadataFor: mainDestination, movedFilesBySource: movedFilesBySource)
        FileStore.upsertMetadata(for: mainDestination, updates: [
            "trashed": true, "trashedAt": ISO8601.now, "originalPath": file.path
        ])
        didMoveMain?(mainDestination)
        return mainDestination
    }

    @discardableResult
    public static func restoreFromTrash(
        file trashedFile: URL,
        fileManager: FileManager = .default,
        didRestoreMain: ((URL) -> Void)? = nil,
        onFailure: ((URL, Error) -> Void)? = nil
    ) -> URL? {
        let recordingsDir = FileStore.recordingsDirectory()
        try? fileManager.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let fileName = trashedFile.lastPathComponent
        let relatedFiles = collectRelatedFiles(for: trashedFile, fileManager: fileManager)

        var restoredFiles: [URL] = []
        var restoredFilesBySource: [URL: URL] = [:]
        var success = true
        var mainRestoredURL: URL? = nil

        for sourceURL in relatedFiles {
            let destinationURL = recordingsDir.appendingPathComponent(sourceURL.lastPathComponent)

            do {
                let actualDestinationURL: URL
                if fileManager.fileExists(atPath: destinationURL.path) {
                    let uniqueName = makeUniqueName(for: sourceURL.lastPathComponent, in: recordingsDir, fileManager: fileManager)
                    actualDestinationURL = recordingsDir.appendingPathComponent(uniqueName)
                } else {
                    actualDestinationURL = destinationURL
                }

                try fileManager.moveItem(at: sourceURL, to: actualDestinationURL)
                restoredFiles.append(actualDestinationURL)
                restoredFilesBySource[sourceURL] = actualDestinationURL

                if sourceURL.lastPathComponent == fileName {
                    mainRestoredURL = actualDestinationURL
                }
            } catch {
                onFailure?(sourceURL, error)
                success = false
                break
            }
        }

        if !success {
            for restoredURL in restoredFiles {
                let trashURL = FileStore.trashDirectory().appendingPathComponent(restoredURL.lastPathComponent)
                try? fileManager.moveItem(at: restoredURL, to: trashURL)
            }
            return nil
        }

        guard let mainRestoredURL else { return nil }
        rewriteAttachmentURLs(inMetadataFor: mainRestoredURL, movedFilesBySource: restoredFilesBySource)
        removeTrashMarker(file: mainRestoredURL)
        didRestoreMain?(mainRestoredURL)
        return mainRestoredURL
    }

    public static func collectRelatedFiles(for file: URL, fileManager: FileManager = .default) -> [URL] {
        var files = Set<URL>()
        let standardFile = file.resolvingSymlinksInPath()
        let metadataURL = FileStore.metadataURL(forRecordingURL: standardFile).resolvingSymlinksInPath()

        if fileManager.fileExists(atPath: standardFile.path) {
            files.insert(standardFile)
        }

        var candidates = [
            FileStore.screenshotURL(forRecordingURL: standardFile),
            FileStore.legacyPNGScreenshotURL(forRecordingURL: standardFile),
            metadataURL,
            FileStore.miniURL(forRecordingURL: standardFile),
            FileStore.metadataURL(forRecordingURL: FileStore.miniURL(forRecordingURL: standardFile)),
            // The current derived tier. Without it a deleted note left its
            // `_micro.m4a` behind as an orphan in Recordings.
            FileStore.microURL(forRecordingURL: standardFile),
            FileStore.metadataURL(forRecordingURL: FileStore.microURL(forRecordingURL: standardFile))
        ]

        candidates.append(contentsOf: FileStore.allScreenshotURLs(forRecordingURL: standardFile))

        for candidate in candidates {
            let standardCandidate = candidate.resolvingSymlinksInPath()
            if fileManager.fileExists(atPath: standardCandidate.path) {
                files.insert(standardCandidate)
            }
        }

        for attachmentURL in attachmentFilesReferenced(byMetadataAt: metadataURL) {
            let standardAttachment = attachmentURL.resolvingSymlinksInPath()
            if fileManager.fileExists(atPath: standardAttachment.path) {
                files.insert(standardAttachment)
            }
        }

        return Array(files).sorted { $0.path < $1.path }
    }

    private static func attachmentFilesReferenced(byMetadataAt metadataURL: URL) -> [URL] {
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let attachments = json["attachments"] as? [[String: Any]] else {
            return []
        }

        return attachments.compactMap { attachment in
            guard let rawURL = attachment["url"] as? String else { return nil }

            if let parsedURL = URL(string: rawURL), parsedURL.isFileURL {
                return parsedURL
            }
            if rawURL.hasPrefix("/") {
                return URL(fileURLWithPath: rawURL)
            }
            return FileStore.resolveRelativePath(rawURL)
        }
    }

    private static func rewriteAttachmentURLs(inMetadataFor file: URL, movedFilesBySource: [URL: URL]) {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }
        try? FileStore.mutateSidecar(at: metaURL) { json in
            guard var attachments = json["attachments"] as? [[String: Any]] else { return false }

            var didChange = false
            for index in attachments.indices {
                guard let rawURL = attachments[index]["url"] as? String else { continue }

                let currentURL: URL?
                if let parsedURL = URL(string: rawURL), parsedURL.isFileURL {
                    currentURL = parsedURL.resolvingSymlinksInPath()
                } else if rawURL.hasPrefix("/") {
                    currentURL = URL(fileURLWithPath: rawURL).resolvingSymlinksInPath()
                } else {
                    currentURL = FileStore.resolveRelativePath(rawURL).resolvingSymlinksInPath()
                }

                guard let currentURL, let movedURL = movedFilesBySource[currentURL] else { continue }
                attachments[index]["url"] = movedURL.absoluteString
                didChange = true
            }

            guard didChange else { return false }
            json["attachments"] = attachments
            return true
        }
    }

    private static func removeTrashMarker(file: URL) {
        let metaURL = FileStore.metadataURL(forRecordingURL: file)
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return }
        try? FileStore.mutateSidecar(at: metaURL) { json in
            let before = json.count
            for key in markerKeys { json.removeValue(forKey: key) }
            return json.count != before
        }
    }

    private static func makeUniqueName(for fileName: String, in directory: URL, fileManager: FileManager) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension

        var counter = 1
        var uniqueName = fileName

        while fileManager.fileExists(atPath: directory.appendingPathComponent(uniqueName).path) {
            uniqueName = "\(base)_\(counter).\(ext)"
            counter += 1
        }

        return uniqueName
    }
}