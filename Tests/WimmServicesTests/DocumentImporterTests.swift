import PDFKit
import WimmTestSupport
import XCTest
import AppKit

import WimmDomain
import WimmInfrastructure

final class DocumentImporterTests: XCTestCase {
    var fileRepo: MockFileRepository!
    var attachRepo: MockAttachmentRepository!
    var metaRepo: MockMetadataRepository!
    var transcriptRepo: MockTranscriptRepository!
    var importer: DocumentImporter!

    override func setUp() async throws {
        try await super.setUp()
        fileRepo = MockFileRepository()
        attachRepo = MockAttachmentRepository()
        metaRepo = MockMetadataRepository()
        transcriptRepo = MockTranscriptRepository()

        importer = DocumentImporter(
            ocrEngine: .vision,  // Use Vision for testing (local, no API key needed)
            fileRepository: fileRepo,
            attachmentRepository: attachRepo,
            transcriptRepository: transcriptRepo,
            metadataRepository: metaRepo
        )
    }

    func testExtractTextFromPDF_NoTextLayer_FallsBackToOCR() async throws {
        // Locate the no_text.pdf fixture
        // We look in Bundle.module (if SPM resources work) or fallback to file system relative path
        let pdfURL: URL
        if let url = Bundle.module.url(forResource: "no_text", withExtension: "pdf") {
            pdfURL = url
        } else {
            // Fallback for when Bundle.module isn't behaving as expected in some envs
            let currentFile = URL(fileURLWithPath: #filePath)
            pdfURL = currentFile.deletingLastPathComponent().appendingPathComponent(
                "Resources/no_text.pdf")
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: pdfURL.path),
            "Fixture not found at \(pdfURL.path)")

        // 1. First verify that without OCR, we get empty text
        // (The fixture has image text but no text layer)
        let noOCRResult = try await importer.extractText(from: pdfURL, allowOCR: false)
        XCTAssertTrue(
            noOCRResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Should have no text without OCR")
        XCTAssertEqual(noOCRResult.provider, "pdfkit")

        // 2. Verify with OCR
        let ocrResult = try await importer.extractText(from: pdfURL, allowOCR: true)
        let normalizedText = ocrResult.text.uppercased()
        XCTAssertTrue(
            normalizedText.contains("HELLO") || normalizedText.contains("WORLD"),
            "OCR should detect text in the image. Got: \(ocrResult.text)"
        )

        // Verify provider/model
        XCTAssertEqual(ocrResult.provider, "vision")
        // Helper method inside DocumentImporter determines this. For .vision engine -> "vision" (TextExtractionProvider.vision)
        // Check DocumentImportService.swift line 305: providerName = TextExtractionProvider.vision
        // WimmInfrastructure/Services/DocumentImportService.swift -> providerName "vision"

        XCTAssertEqual(ocrResult.model, "VNRecognizeText")
    }

    func testMaxOCRPages() async throws {
        let pdfURL = try makeImageOnlyPDF(pageCount: 4)
        let ocrProvider = CountingOCRProvider()
        let deterministicImporter = DocumentImporter(
            ocrEngine: .vision,
            ocrProvider: ocrProvider,
            fileRepository: fileRepo,
            attachmentRepository: attachRepo,
            transcriptRepository: transcriptRepo,
            metadataRepository: metaRepo
        )

        _ = try await deterministicImporter.extractText(
            from: pdfURL,
            allowOCR: true,
            maxOCRPages: 2
        )
        let limitedCalls = await ocrProvider.callCount()
        XCTAssertEqual(limitedCalls, 2, "Should OCR only first 2 pages")

        let clampedProvider = CountingOCRProvider()
        let clampedImporter = DocumentImporter(
            ocrEngine: .vision,
            ocrProvider: clampedProvider,
            fileRepository: fileRepo,
            attachmentRepository: attachRepo,
            transcriptRepository: transcriptRepo,
            metadataRepository: metaRepo
        )

        _ = try await clampedImporter.extractText(
            from: pdfURL,
            allowOCR: true,
            maxOCRPages: 0
        )
        let clampedCalls = await clampedProvider.callCount()
        XCTAssertEqual(clampedCalls, 1, "maxOCRPages=0 should clamp to 1")
    }

    private func makeImageOnlyPDF(pageCount: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "document-importer-\(UUID().uuidString).pdf"
        )
        let doc = PDFDocument()
        let size = NSSize(width: 300, height: 400)

        for _ in 0..<pageCount {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()
            guard let page = PDFPage(image: image) else {
                XCTFail("Failed to create PDF page image")
                continue
            }
            doc.insert(page, at: doc.pageCount)
        }
        guard doc.write(to: url) else {
            throw NSError(
                domain: "DocumentImporterTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to write synthetic PDF fixture"]
            )
        }
        return url
    }
}

private actor CountingOCRProvider: OCRProvider {
    private var calls = 0

    func performOCR(on image: CGImage) async throws -> String {
        calls += 1
        return "mock-ocr-\(calls)"
    }

    func callCount() -> Int {
        calls
    }
}
