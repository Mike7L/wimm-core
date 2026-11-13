import ArgumentParser
import Foundation
import Darwin
import WimmDomain
import WimmInfrastructure

struct PhotoProcessAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "process-all",
        abstract: "Process every image/screenshot to private checkpoints; use apply-results separately to persist in notes")
    @Option(name: .long) var engine = "mlx"
    @Option(name: .long) var output: String
    @Flag(name: .long) var resume = false
    @Flag(name: .long, help: "Stop after writing the full inventory") var inventoryOnly = false

    func run() async throws {
        guard ["vision","mlx"].contains(engine) else { throw ValidationError("--engine must be vision or mlx") }
        let folder = try ImageBatchFiles.output(output)
        let manifestFile = folder.appendingPathComponent("manifest.json")
        let inventory: LibraryImageInventory.Inventory
        if resume {
            inventory = try JSONDecoder().decode(LibraryImageInventory.Inventory.self, from: Data(contentsOf: manifestFile))
        } else {
            guard !FileManager.default.fileExists(atPath: folder.path) else { throw ValidationError("Output exists; use --resume") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            inventory = await LibraryImageInventory.scan()
            try ImageBatchFiles.write(inventory, to: manifestFile)
        }
        if inventoryOnly { print("Inventoried \(inventory.targets.count) references / \(Set(inventory.targets.map(\.image)).count) files"); return }
        let results = folder.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sources = Array(Set(inventory.targets.map(\.image))).sorted(by: >)
        var success = 0, failed = 0, resumed = 0, modelCalls = 0
        let start = Date()
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: source), itemStart = Date()
            let destination = results.appendingPathComponent(ImageBatchRecord.id(for: source) + ".json")
            let digest = try? ImageBatchRecord.hash(url)
            var record = ImageBatchRecord(source: source, sourceSHA256: digest, engine: engine)
            if let data = try? Data(contentsOf: destination), let old = try? JSONDecoder().decode(ImageBatchRecord.self, from: data),
               old.sourceSHA256 == digest, digest != nil, old.pipeline == ImageBatchRecord.currentPipeline {
                record = old
                record.engine = engine
                if record.isComplete { success += 1; resumed += 1; continue }
            }
            record.error = nil
            do {
                guard digest != nil else { throw CocoaError(.fileReadUnknown) }
                let image = try LocalPhotoInput.load(url,minimumSide:1)
                if record.vision == nil {
                    record.vision = try await VisionDocumentAndSceneExtractor.analyze(image: image)
                    try ImageBatchFiles.write(record, to: destination) // Native stage survives an interrupted MLX run.
                }
                if engine == "mlx", record.vision?.isDenseDocument == false, record.vision?.issues.contains("image_too_small_for_recognition") == false, record.caption == nil {
                    modelCalls += 1
                    record.caption = try await LocalPhotoModel.describe(image: image)
                    record.stampCaptionRun()
                }
                guard try ImageBatchRecord.hash(url) == digest else { throw ValidationError("Source changed during extraction") }
                record.completedAt = ISO8601.string(from: Date())
            } catch is CancellationError { throw CancellationError() }
            catch { record.error = error.localizedDescription }
            record.seconds += Date().timeIntervalSince(itemStart)
            try ImageBatchFiles.write(record, to: destination)
            if record.isComplete { success += 1 } else { failed += 1 }
            if (index + 1) % 10 == 0 || !record.isComplete || index + 1 == sources.count {
                print("[\(index+1)/\(sources.count)] complete=\(success) failed=\(failed) modelCalls=\(modelCalls)")
                fflush(nil)
            }
        }
        let summary = BatchSummary(files: sources.count, complete: success, failed: failed, resumed: resumed,
            modelCalls: modelCalls, engine: engine, seconds: Date().timeIntervalSince(start),
            missingAttachments: inventory.missingAttachments, excludedPreviews: inventory.excludedPreviews)
        try ImageBatchFiles.write(summary, to: folder.appendingPathComponent("summary.json"))
        print("Completed \(success)/\(sources.count); failed \(failed). Results are checkpointed; library was not modified.")
        if failed > 0 { throw ExitCode.failure }
    }
}

struct PhotoApplyResults: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "apply-results", abstract: "Apply complete image checkpoints to note sidecars with backups and resume receipts")
    @Option(name: .customLong("run")) var runDirectory: String
    @Flag(name: .long) var apply = false
    func run() async throws {
        let folder = try ImageBatchFiles.output(runDirectory)
        let manifest = try JSONDecoder().decode(LibraryImageInventory.Inventory.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        let lock: Int32?
        if apply {
            let path = StoragePaths.baseDirectory().appendingPathComponent(".image-extraction-apply.lock").path
            let descriptor = Darwin.open(path,O_RDWR | O_CREAT,S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw ValidationError("Cannot open image write lock") }
            guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor);throw ValidationError("Another image apply operation is running")
            }
            lock = descriptor
        } else { lock = nil }
        defer { if let lock { flock(lock,LOCK_UN);close(lock) } }
        let groups = Dictionary(grouping: manifest.targets.filter { $0.note != nil }, by: { $0.note! })
        let backups = folder.appendingPathComponent("sidecar-backups")
        if apply { try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let journal = folder.appendingPathComponent("applied-notes.json")
        var receipts = ((try? Data(contentsOf: journal)).flatMap { try? JSONDecoder().decode([String:ImageApplyReceipt].self, from: $0) }) ?? [:]
        var applied = 0, unchanged = 0, failed = 0, incomplete = 0
        var errors: [String:String] = [:]
        for notePath in groups.keys.sorted() {
            try Task.checkCancellation()
            let note = URL(fileURLWithPath: notePath), sidecar = FileStore.metadataURL(forRecordingURL: note)
            let key = ImageBatchRecord.id(for: sidecar.path)
            var ready: [(LibraryImageInventory.Target, ImageBatchRecord)] = []
            var fingerprints: [String] = []
            for target in groups[notePath] ?? [] {
                let file = folder.appendingPathComponent("results/" + ImageBatchRecord.id(for: target.image) + ".json")
                guard let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(ImageBatchRecord.self, from: data),
                      record.isComplete, record.pipeline == ImageBatchRecord.currentPipeline, record.source == target.image, record.sourceSHA256 == (try? ImageBatchRecord.hash(URL(fileURLWithPath: target.image))) else { incomplete += 1; continue }
                ready.append((target,record))
                fingerprints.append(ImageBatchRecord.id(for:String(decoding:data,as:UTF8.self)) + target.image + target.kind.rawValue)
            }
            guard !ready.isEmpty else { continue }
            let fingerprint = ImageBatchRecord.id(for:fingerprints.sorted().joined(separator:"\n"))
            if let expected = receipts[key], expected.resultsSHA256 == fingerprint,
               (try? ImageBatchRecord.hash(sidecar)) == expected.sidecarSHA256 { unchanged += 1; continue }
            if !apply { applied += ready.count; continue }
            do {
                guard FileManager.default.fileExists(atPath: note.path) else { throw ValidationError("Note no longer exists") }
                if FileManager.default.fileExists(atPath: sidecar.path) {
                    let bytes = try Data(contentsOf: sidecar)
                    guard (try JSONSerialization.jsonObject(with: bytes)) is [String:Any] else { throw ValidationError("Invalid existing sidecar") }
                    let backup = backups.appendingPathComponent(key + ".json")
                    if !FileManager.default.fileExists(atPath: backup.path) {
                        try bytes.write(to: backup, options: .withoutOverwriting)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                    }
                }
                applied += try ImageBatchStore.apply(ready, to: note)
                receipts[key] = ImageApplyReceipt(sidecarSHA256:try ImageBatchRecord.hash(sidecar),resultsSHA256:fingerprint)
                try ImageBatchFiles.write(receipts, to: journal)
            } catch { failed += 1; errors[notePath] = error.localizedDescription; print("Apply failed for note #\(applied+unchanged+failed)") }
        }
        try ImageBatchFiles.write(errors,to:folder.appendingPathComponent(apply ? "apply-errors-private.json" : "apply-preview-errors.json"))
        try ImageBatchFiles.write(["savedReferences":applied,"resumedNotes":unchanged,"failedNotes":failed,"incompleteReferences":incomplete], to: folder.appendingPathComponent(apply ? "apply-summary.json" : "apply-preview.json"))
        print("\(apply ? "Saved" : "Would save"): \(applied) image references; resumed notes \(unchanged); failed \(failed); incomplete references \(incomplete).")
        if failed > 0 { throw ExitCode.failure }
    }
}

private struct ImageApplyReceipt: Codable {
    let sidecarSHA256: String
    let resultsSHA256: String
}
private struct BatchSummary: Codable {
    let files: Int, complete: Int, failed: Int, resumed: Int, modelCalls: Int
    let engine: String
    let seconds: Double
    let missingAttachments: Int, excludedPreviews: Int
}
private enum ImageBatchFiles {
    static func output(_ path: String) throws -> URL {
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let base = StoragePaths.baseDirectory().standardizedFileURL.resolvingSymlinksInPath()
        guard folder != base, !folder.path.hasPrefix(base.path + "/") else { throw ValidationError("Report directory must be outside the library") }
        return folder
    }
    static func write<T:Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
