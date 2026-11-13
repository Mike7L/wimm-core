import Foundation
import CoreGraphics
import WimmDomain

/// Explicit local image tools. A manual MLX request also describes text-heavy images.
public enum ImageUnderstanding {
    public static func extract(_ image: URL, engine: DocumentOCREngine = .vision,
                               forceCaption: Bool = false) async throws -> ImageBatchRecord {
        guard engine == .vision || engine == .mlx else { throw LocalPhotoModel.Failure.unsupported }
        let start = Date(), hash = try ImageBatchRecord.hash(image)
        let raster = try LocalPhotoInput.load(image,minimumSide:1)
        return try await extractRaster(raster,source:image,sourceSHA256:hash,engine:engine,forceCaption:forceCaption,startedAt:start)
    }

    static func extractRaster(_ raster: CGImage, source: URL, sourceSHA256: String,
                              engine: DocumentOCREngine, forceCaption: Bool = false, startedAt: Date = Date()) async throws -> ImageBatchRecord {
        var record = ImageBatchRecord(source:source.standardizedFileURL.resolvingSymlinksInPath().path,sourceSHA256:sourceSHA256,engine:engine.rawValue)
        if engine == .mlx, min(raster.width,raster.height) >= 8 {
            let result = try await LocalPhotoOCRProvider().extract(image:raster,forceCaption:forceCaption)
            record.vision = result.vision; record.caption = result.caption
            record.stampCaptionRun()
        } else { record.vision = try await VisionDocumentAndSceneExtractor.analyze(image:raster) }
        guard try ImageBatchRecord.hash(source) == sourceSHA256 else { throw CocoaError(.fileReadUnknown) }
        record.seconds = Date().timeIntervalSince(startedAt); record.completedAt = ISO8601.string(from:Date())
        return record
    }

    public static func run(note: URL, image: URL? = nil, engine: DocumentOCREngine) async throws -> Int {
        var targets = LibraryImageInventory.targets(for:note)
        if let image {
            let source = image.standardizedFileURL.resolvingSymlinksInPath().path
            targets = targets.filter { $0.image == source }
        }
        guard !targets.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        var count = 0
        for target in targets {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath:target.image)
            let record = try await extract(url,engine:engine,forceCaption:engine == .mlx)
            guard try ImageBatchRecord.hash(url) == record.sourceSHA256 else { throw CocoaError(.fileReadUnknown) }
            guard FileManager.default.fileExists(atPath:note.path) else { throw CocoaError(.fileNoSuchFile) }
            let saved = try ImageBatchStore.apply([(target,record)],to:note)
            guard saved > 0 else { throw CocoaError(.fileWriteNoPermission) }
            count += saved
        }
        return count
    }
}

/// Keep distinct structured runs, including a previous caption after a native-only retry.
public enum ImageAnalysisHistory {
    public static func store(_ record: ImageBatchRecord, in container: inout [String:Any]) throws {
        var value = try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as! [String:Any]
        value["source"] = FileStore.relativePath(for:URL(fileURLWithPath:record.source))
        if let previous = container["imageAnalysis"] as? [String:Any],
           !NSDictionary(dictionary:previous).isEqual(to:value) {
            var history = container["previousImageAnalyses"] as? [[String:Any]] ?? []
            if !history.contains(where:{ NSDictionary(dictionary:$0).isEqual(to:previous) }) { history.append(previous) }
            container["previousImageAnalyses"] = history
        }
        container["imageAnalysis"] = value
    }
}
