import Foundation

/// A rebuildable, per-image observation; never an entity/fact registry. Confidence is
/// Vision's own score, not calibrated factual accuracy. Barcode payloads are data, not actions.
public struct VisionImageAnalysis: Codable, Sendable {
    public struct Code: Codable, Sendable, Equatable {
        public let symbology: String
        public let payload: String
        public let confidence: Float
    }
    public struct Datum: Codable, Sendable, Equatable {
        public let kind: String
        public let text: String
    }
    public let ocrText: String
    public let scene: String?
    public let sceneObservation: VisionSceneObservation?
    public let codes: [Code]
    public let detectedData: [Datum]
    public let isDenseDocument: Bool
    public let documentEngine: String
    /// Empty results from a failed detector must not masquerade as successful negatives.
    public let issues: [String]
    public var layout: DocumentLayoutEvidence? = nil

    public var text: String {
        var blocks: [String] = []
        if let scene { blocks.append(scene) }
        if !ocrText.isEmpty { blocks.append(ocrText) }
        for code in codes where !ocrText.contains(code.payload) {
            blocks.append("[barcode \(code.symbology): \(code.payload)]")
        }
        if !detectedData.isEmpty {
            blocks.append("[detected data from OCR]\n" + detectedData.map { "- \($0.kind): \($0.text)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Diagnostic only. No confidence-based caption omission is enabled from this flag.
    /// A human must judge whether tags lose relationships/details present in a caption.
    public var hasSceneSearchLabels: Bool { scene != nil }
}
