import Foundation
import CryptoKit

public struct ImageBatchRecord: Codable, Sendable {
    public static let currentPipeline = "vision-layout-2026-10-29-v3"
    public struct ModelSnapshot: Codable, Sendable {
        public let identifier: String, configuredRevision: String
        public let promptVersion: String?, configSHA256: String?
        public let seed: Int, maxTokens: Int, maximumImageSide: Int
        public let temperature: Double, repetitionPenalty: Double
        public let runtimeVersions: [String:String]?
    }
    public let source: String
    public let sourceSHA256: String?
    public let pipeline: String
    public var engine: String
    public var vision: VisionImageAnalysis?
    public var caption: LocalPhotoModel.Caption?
    public var error: String?
    public var seconds: Double
    public var completedAt: String?
    public var modelSnapshot: ModelSnapshot? = nil

    public init(source: String, sourceSHA256: String?, engine: String) {
        self.source = source; self.sourceSHA256 = sourceSHA256; self.engine = engine
        self.pipeline = Self.currentPipeline; self.seconds = 0
    }
    public var isComplete: Bool {
        guard error == nil, let vision else { return false }
        return engine == "vision" || vision.isDenseDocument || vision.issues.contains("image_too_small_for_recognition") || caption != nil
    }
    public var text: String {
        guard let vision else { return "" }
        if let caption { return LocalPhotoOCRProvider.combine(caption: caption.caption, text: vision.text) }
        return vision.text
    }
    public var model: String {
        let native = vision?.documentEngine ?? "Apple Vision"
        return caption == nil ? native : (modelSnapshot?.identifier ?? "MLX legacy run (model not stamped)") + " + " + native
    }
    public mutating func stampCaptionRun() {
        guard let caption else { return }
        let brief = caption.promptMode == "brief_retry"
        modelSnapshot = ModelSnapshot(identifier:LocalPhotoModel.identifier,
            configuredRevision:"da28692b5f139cb0ec58a356b437486b7dac7462",
            promptVersion:caption.promptVersion,configSHA256:caption.modelConfigSHA256,seed:42,
            maxTokens:brief ? 64 : 128,maximumImageSide:LocalPhotoModel.maximumImageSide,
            temperature:0.1,repetitionPenalty:brief ? 1.15 : 1.1,runtimeVersions:caption.runtimeVersions)
    }
    public var provider: String { caption == nil ? "vision" : "on-device" }
    public static func id(for source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
