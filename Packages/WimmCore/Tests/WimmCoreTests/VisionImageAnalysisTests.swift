import XCTest
import CoreGraphics
import CoreImage
#if canImport(AppKit)
import AppKit
#endif
@testable import WimmInfrastructure

final class VisionImageAnalysisTests: XCTestCase {
    func testBarcodeIsPreservedEvenWithoutOCRAndNotDuplicated() {
        let code = VisionImageAnalysis.Code(symbology: "qr", payload: "https://example.com/control", confidence: 1)
        let value = VisionImageAnalysis(ocrText: "", scene: nil, sceneObservation: nil,
            codes: [code], detectedData: [], isDenseDocument: false, documentEngine: "test", issues: [])
        XCTAssertTrue(value.text.contains("[barcode qr: https://example.com/control]"))
        let alreadyVisible = VisionImageAnalysis(ocrText: code.payload, scene: nil, sceneObservation: nil,
            codes: [code], detectedData: [], isDenseDocument: false, documentEngine: "test", issues: [])
        XCTAssertEqual(alreadyVisible.text, code.payload)
    }

    func testStructuredDataKeepsLiteralDateAndAmount() throws {
        let raw = "Оплата 28 октября 2026. Сумма 12,50 EUR."
        let value = VisionImageAnalysis(ocrText: raw, scene: "[scene: receipt]", sceneObservation: nil,
            codes: [], detectedData: [.init(kind: "money", text: "12,50 EUR"), .init(kind: "date_or_time", text: "28 октября 2026")],
            isDenseDocument: false, documentEngine: "test", issues: ["classification_failed"])
        XCTAssertTrue(value.text.contains(raw))
        XCTAssertTrue(value.text.contains("money: 12,50 EUR"))
        let decoded = try JSONDecoder().decode(VisionImageAnalysis.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(decoded.detectedData, value.detectedData)
        XCTAssertEqual(decoded.issues, ["classification_failed"])
        XCTAssertTrue(decoded.hasSceneSearchLabels) // Labels alone don't authorize caption omission.
    }

    func testRealVisionDecodesSyntheticQRWithoutFollowingURL() async throws {
        let payload = "https://example.com/wimm-test?code=204"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let qrImage = try XCTUnwrap(CIContext(options: [.useSoftwareRenderer: true]).createCGImage(qr, from: qr.extent))
        let size = qrImage.width + 96
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.interpolationQuality = .none
        context.draw(qrImage, in: CGRect(x: 48, y: 48, width: qrImage.width, height: qrImage.height))
        let analysis = try await VisionDocumentAndSceneExtractor.analyze(image: XCTUnwrap(context.makeImage()))
        XCTAssertEqual(analysis.codes.filter { $0.payload == payload }.count, 1)
        XCTAssertTrue(analysis.text.contains(payload))
        XCTAssertFalse(analysis.issues.contains("barcode_detection_failed"))
    }

    #if canImport(AppKit)
    func testNativeDataDetectionReturnsOriginalEmailAndAmountSpelling() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Modern structured data requires macOS 26") }
        let image = NSImage(size: NSSize(width: 1600, height: 900))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 900).fill()
        let lines = ["CONTACT DETAILS", "Email: secretary@example.com", "Website: https://example.com", "Total: 12.50 EUR", "Date: October 28, 2026"]
        for (i, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 80, y: 760 - i * 130), withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black])
        }
        image.unlockFocus()
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let result = try await VisionDocumentAndSceneExtractor.analyze(image: cg)
        XCTAssertTrue(result.detectedData.contains { $0.kind == "email" && $0.text == "secretary@example.com" })
        XCTAssertTrue(result.detectedData.contains { $0.kind == "money" && $0.text.contains("12.50") })
        XCTAssertTrue(result.detectedData.allSatisfy { result.ocrText.contains($0.text) })
    }
    #endif
}
