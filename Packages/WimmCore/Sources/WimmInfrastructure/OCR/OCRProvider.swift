import CoreGraphics
import Foundation

public protocol OCRProvider: Sendable {
    func performOCR(on image: CGImage) async throws -> String
}
