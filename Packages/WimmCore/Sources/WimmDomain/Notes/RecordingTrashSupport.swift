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

        // A same-name file already in Trash (an earlier note with this name,
        // deleted before) is never overwritten: the whole group moves under
        // one free base name, so the sidecar still sits next to its media.
        let destinations = freeDestinations(
            for: relatedFiles,
            mainFile: file.resolvingSymlinksInPath(),
            desiredBase: file.deletingPathExtension().lastPathComponent,
            in: trashDir,
            fileManager: fileManager
        )

        var movedFilesBySource: [URL: URL] = [:]
        var mainDestination: URL?
        var success = true

        for sourceURL in relatedFiles {
            guard let destinationURL = destinations[sourceURL] else { continue }
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                movedFilesBySource[sourceURL] = destinationURL
                if sourceURL.lastPathComponent == fileName { mainDestination = destinationURL }
            } catch {
                onFailure?(sourceURL, error)
                success = false
                break
            }
        }

        if !success {
            for (sourceURL, movedURL) in movedFilesBySource {
                try? fileManager.moveItem(at: movedURL, to: sourceURL)
            }
            return nil
        }

        guard let mainDestination else { return nil }

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

        // A note trashed under a suffixed name (its name was taken in Trash)
        // goes back under the name it had, read from the trash marker.
        let desiredBase = originalBase(forTrashed: trashedFile)
            ?? trashedFile.deletingPathExtension().lastPathComponent
        let destinations = freeDestinations(
            for: relatedFiles,
            mainFile: trashedFile.resolvingSymlinksInPath(),
            desiredBase: desiredBase,
            in: recordingsDir,
            fileManager: fileManager
        )

        var restoredFilesBySource: [URL: URL] = [:]
        var success = true
        var mainRestoredURL: URL? = nil

        for sourceURL in relatedFiles {
            guard let actualDestinationURL = destinations[sourceURL] else { continue }
            do {
                try fileManager.moveItem(at: sourceURL, to: actualDestinationURL)
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
            for (sourceURL, restoredURL) in restoredFilesBySource {
                try? fileManager.moveItem(at: restoredURL, to: sourceURL)
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

    /// Destination for every file of a note's group in `directory`. Files
    /// named after the main file's base keep their suffix under one shared
    /// base: `desiredBase` if all those names are free, else `desiredBase_1`,
    /// `_2`, … Any other file (an attachment with its own name) gets its own
    /// free name. Nothing existing is ever overwritten.
    static func freeDestinations(
        for files: [URL],
        mainFile: URL,
        desiredBase: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL: URL] {
        let sourceBase = mainFile.deletingPathExtension().lastPathComponent
        let grouped = files.filter { $0.lastPathComponent.hasPrefix(sourceBase) }
        let others = files.filter { !$0.lastPathComponent.hasPrefix(sourceBase) }

        func taken(_ name: String) -> Bool {
            fileManager.fileExists(atPath: directory.appendingPathComponent(name).path)
        }

        // The note's companions are found by name, so a base is only free if
        // no orphan sidecar or derived copy under it waits there either.
        let companionSuffixes = [".meta.json", ".metadata.json", ".heic", ".png", "_micro.m4a", "_mini.m4a"]
        func baseIsTaken(_ base: String) -> Bool {
            grouped.contains { taken(base + $0.lastPathComponent.dropFirst(sourceBase.count)) }
                || companionSuffixes.contains { taken(base + $0) }
        }

        var counter = 0
        var base = desiredBase
        while baseIsTaken(base) {
            counter += 1
            base = "\(desiredBase)_\(counter)"
        }

        var result: [URL: URL] = [:]
        var claimed = Set<String>()
        for source in grouped {
            let name = base + source.lastPathComponent.dropFirst(sourceBase.count)
            claimed.insert(name)
            result[source] = directory.appendingPathComponent(name)
        }
        for source in others {
            let name = makeUniqueName(for: source.lastPathComponent, in: directory, fileManager: fileManager, claimed: claimed)
            claimed.insert(name)
            result[source] = directory.appendingPathComponent(name)
        }
        return result
    }

    /// The base name the note had before it went to Trash, from the marker's
    /// `originalPath`, when it has the same extension as the trashed file.
    private static func originalBase(forTrashed trashedFile: URL) -> String? {
        let metaURL = FileStore.metadataURL(forRecordingURL: trashedFile)
        guard let data = try? Data(contentsOf: metaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["originalPath"] as? String, !path.isEmpty else { return nil }
        let original = URL(fileURLWithPath: path)
        guard original.pathExtension == trashedFile.pathExtension else { return nil }
        let base = original.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base != ".", base != "..", !base.contains("/") else { return nil }
        return base
    }

    private static func makeUniqueName(
        for fileName: String,
        in directory: URL,
        fileManager: FileManager,
        claimed: Set<String> = []
    ) -> String {
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension

        var counter = 1
        var uniqueName = fileName

        while claimed.contains(uniqueName)
            || fileManager.fileExists(atPath: directory.appendingPathComponent(uniqueName).path) {
            uniqueName = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            counter += 1
        }

        return uniqueName
    }
}