import CoreGraphics
import ImageIO
import XCTest

import WimmDomain
import WimmInfrastructure

final class OCRProviderTests: XCTestCase {

    // MARK: - VisionOCRProvider Tests

    func testVisionOCRProvider_ExtractsTextFromImage() async throws {
        // Load test image from Resources (no_text.pdf first page as CGImage)
        let pdfURL = try loadTestPDF()
        guard let cgImage = renderPDFPageToImage(pdfURL: pdfURL, pageIndex: 0) else {
            XCTFail("Failed to render PDF page to CGImage")
            return
        }

        let provider = VisionOCRProvider()
        let text = try await provider.performOCR(on: cgImage)

        XCTAssertFalse(text.isEmpty, "VisionOCRProvider should extract text from image")
        XCTAssertTrue(
            text.uppercased().contains("HELLO") || text.uppercased().contains("WORLD"),
            "Should detect 'HELLO WORLD' text in the image. Got: \(text)"
        )
    }

    func testVisionOCRProvider_EmptyImageReturnsEmptyOrMinimalText() async throws {
        // Create a blank white image
        let blankImage = createBlankImage(width: 100, height: 100)

        let provider = VisionOCRProvider()
        let text = try await provider.performOCR(on: blankImage)

        // A blank image should return empty or nearly empty text
        XCTAssertTrue(
            text.trimmingCharacters(in: .whitespacesAndNewlines).count < 10,
            "Blank image should produce minimal text. Got: \(text)"
        )
    }

    // MARK: - OCRProvider Protocol Tests

    func testOCRProviderProtocol_VisionConforms() {
        let provider: any OCRProvider = VisionOCRProvider()
        XCTAssertNotNil(provider)
    }

    func testOCRProviderProtocol_GeminiConforms() {
        let provider: any OCRProvider = GeminiOCRProvider(model: "test-model", transport: .shared)
        XCTAssertNotNil(provider)
    }

    func testOCRProviderProtocol_OpenRouterConforms() {
        let provider: any OCRProvider = OpenRouterOCRProvider(
            model: "test-model", transport: .shared)
        XCTAssertNotNil(provider)
    }

    // MARK: - Helpers

    private func loadTestPDF() throws -> URL {
        if let url = Bundle.module.url(forResource: "no_text", withExtension: "pdf") {
            return url
        }
        let currentFile = URL(fileURLWithPath: #filePath)
        let pdfURL = currentFile.deletingLastPathComponent().appendingPathComponent(
            "Resources/no_text.pdf")
        guard FileManager.default.fileExists(atPath: pdfURL.path) else {
            throw NSError(
                domain: "OCRProviderTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Test PDF not found"])
        }
        return pdfURL
    }

    private func renderPDFPageToImage(pdfURL: URL, pageIndex: Int) -> CGImage? {
        guard let provider = CGDataProvider(url: pdfURL as CFURL),
            let pdfDoc = CGPDFDocument(provider),
            let page = pdfDoc.page(at: pageIndex + 1)
        else {
            return nil
        }

        let pageRect = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2.0
        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(page)

        return context.makeImage()
    }

    private func createBlankImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()!
    }
}
