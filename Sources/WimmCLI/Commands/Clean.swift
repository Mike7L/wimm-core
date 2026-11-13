import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cleanup invalid files and reclaim disk space",
        subcommands: [CleanGhosts.self, CleanOriginals.self, CleanDerived.self],
        defaultSubcommand: CleanGhosts.self
    )
}

struct CleanDerived: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "derived",
        abstract: "Delete invalid cascaded audio derivatives such as _micro_mini",
        discussion: """
        A derived file is deleted only while its original recording (a non-derived \
        audio file with the same base name in the same directory) still exists. \
        Derived files without one are the note's only remaining audio: they are \
        listed as "orphan, kept" and never deleted, with or without --force.
        """
    )

    @Flag(name: .long, help: "Delete the files immediately")
    var force: Bool = false

    @Flag(name: .long, help: "Also delete legacy _mini files (the retired tier; regenerable as _micro), wherever they live under the app container")
    var mini: Bool = false

    @Flag(name: .long, help: "Print every candidate and orphan instead of the first 20")
    var list: Bool = false

    func run() throws {
        let fm = FileManager.default
        let recDir = FileStore.recordingsDirectory()
        var files: [URL] = try fm.contentsOfDirectory(
            at: recDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        if mini {
            // Legacy _mini files also live next to transcribed attachments (e.g.
            // Attachments/Evernote/...) and in Trash; sweep the whole container.
            let container = recDir.deletingLastPathComponent()
            if let enumerator = fm.enumerator(
                at: container,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                while let item = enumerator.nextObject() {
                    guard let url = item as? URL, url.pathExtension.lowercased() == "m4a" else { continue }
                    files.append(url)
                }
            }
        }
        var seen = Set<String>()
        var sizes: [String: Int64] = [:]
        let matches = try files.filter { url in
            guard seen.insert(url.path).inserted else { return false }
            guard DerivedAudioCleanupPlanner.isCandidate(url, includeLegacyMini: mini) else { return false }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return false }
            sizes[url.path] = Int64(values.fileSize ?? 0)
            return true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let plan = DerivedAudioCleanupPlanner.plan(candidates: matches, fileManager: fm)
        func size(_ urls: [URL]) -> String {
            ByteCountFormatter.string(fromByteCount: urls.reduce(Int64(0)) { $0 + (sizes[$1.path] ?? 0) }, countStyle: .file)
        }
        func printList(_ urls: [URL]) {
            let shown = list ? urls[...] : urls.prefix(20)
            for url in shown { print(" - \(displayPath(url, container: recDir.deletingLastPathComponent()))") }
            if urls.count > shown.count { print(" ... and \(urls.count - shown.count) more (use --list to see all)") }
        }

        let label = mini ? "Cascaded + legacy _mini derived audio" : "Cascaded derived audio"
        print("\(label): \(plan.deletable.count) file(s) with an original, \(size(plan.deletable))")
        if !plan.orphans.isEmpty {
            print("Orphan, kept (no original audio — the only copy of the note's audio): \(plan.orphans.count) file(s), \(size(plan.orphans))")
        }
        guard force else {
            if !plan.deletable.isEmpty {
                print("To delete:")
                printList(plan.deletable)
            }
            if !plan.orphans.isEmpty {
                print("Orphan, kept:")
                printList(plan.orphans)
            }
            if !plan.deletable.isEmpty { print("Run with --force to delete them.") }
            return
        }

        var deleted = 0
        for url in plan.deletable {
            do {
                try fm.removeItem(at: url)
                deleted += 1
            } catch {
                print("Failed to delete \(url.lastPathComponent): \(error)")
            }
        }
        print("Deleted \(deleted) derived audio file(s); kept \(plan.orphans.count) orphan(s).")
    }

    private func displayPath(_ url: URL, container: URL) -> String {
        let prefix = container.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

struct CleanGhosts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ghosts",
        abstract: "Cleanup invalid files (Ghost Metadata)"
    )

    @Flag(name: .long, help: "Delete the files immediately")
    var force: Bool = false

    func run() throws {
        let fm = FileManager.default
        let recDir = FileStore.recordingsDirectory()
        
        print("🧹 WIMM Cleaner")
        print("Scanning: \(recDir.path)")
        
        let files = try fm.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)
        
        let supportedAudio = FileStore.supportedAudioExtensions
        let supportedDocs = FileStore.supportedDocumentExtensions
        
        // Identify valid content bases
        let primaryFiles = Set(files.compactMap { url -> String? in
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent

            if supportedAudio.contains(ext) {
                return FileStore.strippingDerivedAudioSuffix(base)
            } else if supportedDocs.contains(ext) {
                return base
            }
            return nil
        })
        
        // Identify meta files
        let metaFiles = Set(files.filter { 
            $0.pathExtension == "json" && $0.lastPathComponent.contains(".meta") 
        }.map { $0.lastPathComponent.replacingOccurrences(of: ".meta.json", with: "") })
        
        // Ghost Meta = Meta exists, but no Primary Content (Audio/Doc/Mini)
        let ghostMeta = metaFiles.subtracting(primaryFiles)
        
        if ghostMeta.isEmpty {
            print("✅ No ghost metadata found. All clear.")
            return
        }
        
        print("⚠️ Found \(ghostMeta.count) ghost metadata files (meta without content).")
        
        if force {
            print("\n🗑️ Deleting files...")
            var deletedCount = 0
            for id in ghostMeta {
                let filename = id + ".meta.json"
                let url = recDir.appendingPathComponent(filename)
                do {
                    try fm.removeItem(at: url)
                    print("   Deleted: \(filename)")
                    deletedCount += 1
                } catch {
                    print("   ❌ Failed to delete \(filename): \(error)")
                }
            }
            print("\n✅ Deleted \(deletedCount) files.")
        } else {
            print("\nPreview of files to delete:")
            for id in ghostMeta.prefix(10) {
                print(" - \(id).meta.json")
            }
            if ghostMeta.count > 10 { print(" ... and \(ghostMeta.count - 10) more") }
            print("\n⚠️ Run with --force to actually delete these files.")
        }
    }
}

struct CleanOriginals: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "originals",
        abstract: "Delete large original audio files when a _micro copy exists (requires --accept-micro-as-only-copy)",
        discussion: """
        Refuses to run by default. This command used to delete originals whenever a \
        _mini existed; the _mini tier is retired, and `clean derived --mini` later \
        deleted those minis — for 267 notes that was the last audio. A _mini never \
        qualifies any more. _micro is 16 kHz mono and may have its silences cut, so \
        it is a lossy, shortened stand-in: deleting the original makes _micro the \
        only copy, and `clean derived` will then keep it as an orphan. Pass \
        --accept-micro-as-only-copy to opt in.
        """
    )

    @Flag(name: .long, help: "Delete the files immediately")
    var force: Bool = false

    @Option(name: .long, help: "Minimum original size to delete, in MB")
    var minMB: Double = 1.0

    @Flag(name: .long, help: "Accept that the 16 kHz, possibly silence-trimmed _micro becomes the only audio of each affected note")
    var acceptMicroAsOnlyCopy: Bool = false

    func run() throws {
        guard acceptMicroAsOnlyCopy else {
            print("Refusing: `clean originals` would leave a derived file as the only audio of each note.")
            print("_mini no longer counts as a copy (retired tier). To delete originals that have a")
            print("_micro copy, re-run with --accept-micro-as-only-copy (dry-run first, then --force).")
            throw ExitCode.failure
        }
        let fm = FileManager.default
        let recDir = FileStore.recordingsDirectory()
        let minBytes = Int64(max(0, minMB) * 1024 * 1024)

        print("🧹 WIMM Original Audio Cleaner")
        print("Scanning: \(recDir.path)")
        print("Threshold: \(String(format: "%.2f", minMB)) MB")

        let files = try fm.contentsOfDirectory(
            at: recDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        let candidates = try files.compactMap { url -> Candidate? in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return nil }
            guard FileStore.isAudioFile(url) else { return nil }
            guard !FileStore.isDerivedAudioFile(url) else { return nil }
            guard !FileStore.isAttachmentFile(url) else { return nil }

            let size = Int64(values.fileSize ?? 0)
            guard size > minBytes else { return nil }

            let micro = FileStore.microURL(forRecordingURL: url)
            guard let microSize = try? micro.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  microSize > 0 else { return nil }

            return Candidate(original: url, micro: micro, bytes: size)
        }.sorted { $0.original.lastPathComponent < $1.original.lastPathComponent }

        guard !candidates.isEmpty else {
            print("✅ No large originals with _micro copies found.")
            return
        }

        let reclaimable = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        print("Found \(candidates.count) original files reclaiming \(formatBytes(reclaimable)).")

        if force {
            print("\n🗑️ Deleting originals...")
            var deletedCount = 0
            var deletedBytes: Int64 = 0

            for candidate in candidates {
                do {
                    try fm.removeItem(at: candidate.original)
                    deletedCount += 1
                    deletedBytes += candidate.bytes
                    print("   Deleted: \(candidate.original.lastPathComponent) (\(formatBytes(candidate.bytes)))")
                } catch {
                    print("   ❌ Failed to delete \(candidate.original.lastPathComponent): \(error)")
                }
            }

            print("\n✅ Deleted \(deletedCount) files, reclaimed \(formatBytes(deletedBytes)).")
        } else {
            print("\nPreview of originals to delete:")
            for candidate in candidates.prefix(20) {
                print(" - \(candidate.original.lastPathComponent) (\(formatBytes(candidate.bytes)))")
            }
            if candidates.count > 20 {
                print(" ... and \(candidates.count - 20) more")
            }
            print("\n⚠️ Run with --force to actually delete these files.")
        }
    }

    private struct Candidate {
        let original: URL
        let micro: URL
        let bytes: Int64
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
