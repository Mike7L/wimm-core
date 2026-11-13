import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

struct PhotoCaptionResults: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName:"caption-results",
        abstract:"Add MLX captions to completed native checkpoints in bounded batches; resume automatically")
    @Option(name:.customLong("run")) var runDirectory: String
    @Option(name:.long) var batchSize = 32
    func run() async throws {
        guard (1...32).contains(batchSize),LocalPhotoModel.isReady else { throw ValidationError("Batch size must be 1...32 and the local model must be installed") }
        let folder = URL(fileURLWithPath:(runDirectory as NSString).expandingTildeInPath)
        let inventory = try JSONDecoder().decode(LibraryImageInventory.Inventory.self,from:Data(contentsOf:folder.appendingPathComponent("manifest.json")))
        let sources = Array(Set(inventory.targets.map(\.image))).sorted(by:>)
        var pending: [LocalPhotoBatch.Item] = [],dense = 0,cached = 0,nativeMissing = 0,tooSmall = 0
        let sink = CaptionCheckpointSink(folder:folder)
        for source in sources {
            let file = folder.appendingPathComponent("results/"+ImageBatchRecord.id(for:source)+".json")
            guard let bytes = try? Data(contentsOf:file),var record = try? JSONDecoder().decode(ImageBatchRecord.self,from:bytes),
                  record.pipeline == ImageBatchRecord.currentPipeline,let vision = record.vision,
                  record.sourceSHA256 == (try? ImageBatchRecord.hash(URL(fileURLWithPath:source))) else { nativeMissing += 1;continue }
            record.engine = "mlx"
            if vision.issues.contains("image_too_small_for_recognition") { record.error = nil;tooSmall += 1;try await sink.save(record);continue }
            if vision.isDenseDocument { record.error = nil;dense += 1;try await sink.save(record);continue }
            if record.caption != nil { record.error = nil;cached += 1;try await sink.save(record);continue }
            pending.append(.init(id:ImageBatchRecord.id(for:source),image:URL(fileURLWithPath:source)))
        }
        print("Dense documents: \(dense); cached captions: \(cached); pending captions: \(pending.count); native unavailable: \(nativeMissing)");fflush(nil)
        let start = Date()
        for index in stride(from:0,to:pending.count,by:batchSize) {
            try Task.checkCancellation()
            let items = Array(pending[index..<min(pending.count,index+batchSize)])
            do {
                try await LocalPhotoBatch.describe(items) { id,caption,error in try await sink.receive(id:id,caption:caption,error:error) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                for item in items { try await sink.failIfPending(id:item.id,error:error.localizedDescription) }
            }
            let counts = await sink.counts
            print("[\(min(pending.count,index+batchSize))/\(pending.count)] captions=\(counts.ok) failed=\(counts.failed)");fflush(nil)
        }
        let counts = await sink.counts
        let report: [String:Any] = ["files":sources.count,"dense":dense,"cachedCaptions":cached,"captioned":counts.ok,
            "failed":counts.failed,"nativeUnavailable":nativeMissing,"tooSmallForRecognition":tooSmall,"seconds":Date().timeIntervalSince(start),"batchSize":batchSize]
        try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]).write(to:folder.appendingPathComponent("caption-summary.json"),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:folder.appendingPathComponent("caption-summary.json").path)
        if counts.failed > 0 || nativeMissing > 0 { throw ExitCode.failure }
    }
}

private actor CaptionCheckpointSink {
    let folder: URL
    var counts = (ok:0,failed:0)
    init(folder:URL) { self.folder = folder }
    func save(_ record:ImageBatchRecord) throws {
        let file = folder.appendingPathComponent("results/"+ImageBatchRecord.id(for:record.source)+".json")
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        try encoder.encode(record).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func receive(id:String,caption:LocalPhotoModel.Caption?,error:String?) throws {
        let file = folder.appendingPathComponent("results/"+id+".json")
        var record = try JSONDecoder().decode(ImageBatchRecord.self,from:Data(contentsOf:file))
        guard ImageBatchRecord.id(for:record.source) == id,
              record.sourceSHA256 == (try? ImageBatchRecord.hash(URL(fileURLWithPath:record.source))) else { throw ValidationError("Caption source changed") }
        record.engine = "mlx";record.caption = caption;record.error = error
        record.stampCaptionRun()
        record.completedAt = ISO8601.string(from:Date());record.seconds += caption?.seconds ?? 0
        try save(record)
        if record.isComplete { counts.ok += 1 } else { counts.failed += 1 }
    }
    func failIfPending(id:String,error:String) throws {
        let file = folder.appendingPathComponent("results/"+id+".json")
        let record = try JSONDecoder().decode(ImageBatchRecord.self,from:Data(contentsOf:file))
        if record.caption == nil && record.error == nil { try receive(id:id,caption:nil,error:error) }
    }
}
