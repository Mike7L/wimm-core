import Foundation
import CoreGraphics
import WimmDomain

/// Rebuildable detector output, not a verified semantic document model.
public struct DocumentLayoutEvidence: Codable, Sendable {
    public struct Box: Codable, Sendable, Equatable {
        public let x: Double, y: Double, width: Double, height: Double
        public init(_ rect: CGRect) {
            x = Double(rect.minX); y = Double(rect.minY)
            width = Double(rect.width); height = Double(rect.height)
        }
    }
    public struct Line: Codable, Sendable {
        public let id: String, text: String
        public let box: Box
        public let confidence: Float?
        public let alternatives: [String]
    }
    public struct Block: Codable, Sendable {
        public let id: String, kind: String, text: String
        public let box: Box
    }
    public struct Cell: Codable, Sendable {
        public let id: String, rowStart: Int, rowEnd: Int, columnStart: Int, columnEnd: Int
        public let text: String
        public let box: Box
    }
    public struct Table: Codable, Sendable {
        public let id: String
        public let box: Box
        public let cells: [Cell]
    }
    public let schema: Int
    public let coordinateSystem: String
    public let imageWidth: Int, imageHeight: Int
    public let rawText: String
    public let lines: [Line]
    public let blocks: [Block]
    public let tables: [Table]
    public let structureStatus: String
    public let selectionStateStatus: String
    public init(imageWidth: Int, imageHeight: Int, rawText: String, lines: [Line], blocks: [Block] = [], tables: [Table] = []) {
        schema = 1; coordinateSystem = "normalized-bottom-left-on-oriented-raster"
        self.imageWidth = imageWidth; self.imageHeight = imageHeight; self.rawText = rawText
        self.lines = lines; self.blocks = blocks; self.tables = tables
        structureStatus = "detected_unverified; Markdown may misalign cells or join independent columns"
        selectionStateStatus = "not_extracted; printed yes/no alternatives do not establish a selected checkbox"
    }
}

public struct DocumentPageEvidence: Codable, Sendable {
    public let page: Int
    public let text: String
    public let provider: String
    public let analysis: ImageBatchRecord?
    public let error: String?
    public init(page: Int, text: String, provider: String, analysis: ImageBatchRecord? = nil, error: String? = nil) {
        self.page = page; self.text = text; self.provider = provider; self.analysis = analysis; self.error = error
    }

    public static func store(_ pages: [DocumentPageEvidence], sourceSHA256: String?, in document: inout [String:Any]) throws {
        let value = try JSONSerialization.jsonObject(with:JSONEncoder().encode(pages)) as! [[String:Any]]
        if let old = document["pages"] as? [[String:Any]], !NSArray(array:old).isEqual(to:value) {
            var history = document["previousPageRuns"] as? [[String:Any]] ?? []
            history.append(["pages":old,"sourceSHA256":document["sourceSHA256"] ?? NSNull(),"replacedAt":ISO8601.string(from:Date())])
            document["previousPageRuns"] = history
        }
        document["pages"] = value;document["pagesSchema"] = 1;document["sourceSHA256"] = sourceSHA256
        document["pagesExtractedAt"] = ISO8601.string(from:Date())
    }
    public static func save(_ pages: [DocumentPageEvidence], sourceSHA256: String?, to note: URL, attachmentID: UUID? = nil) throws {
        guard FileManager.default.fileExists(atPath:note.path) else { throw CocoaError(.fileNoSuchFile) }
        try FileStore.mutateSidecar(at:FileStore.metadataURL(forRecordingURL:note)) { meta in
            if let attachmentID {
                var list = meta["attachments"] as? [[String:Any]] ?? []
                guard let index = list.firstIndex(where:{ ($0["id"] as? String).flatMap(UUID.init(uuidString:)) == attachmentID }) else { throw CocoaError(.fileNoSuchFile) }
                try store(pages,sourceSHA256:sourceSHA256,in:&list[index]);meta["attachments"] = list
            } else {
                var document = meta["document"] as? [String:Any] ?? [:]
                try store(pages,sourceSHA256:sourceSHA256,in:&document);meta["document"] = document
            }
            return true
        }
    }
}
