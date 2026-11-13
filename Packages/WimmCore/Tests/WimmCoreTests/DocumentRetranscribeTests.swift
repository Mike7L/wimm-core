import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// Re-processing a document note must never destroy it: the image/PDF, its
/// metadata (sync ID, NoteCard, attachments) and its transcript are the note.
final class DocumentRetranscribeTests: XCTestCase {
    private struct StubOCRProvider: OCRProvider {
        let text: String
        func performOCR(on image: CGImage) async throws -> String { text }
    }

    private func makeEnvIsolatedBase() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-retranscribe-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tmp.path, 1)
        try FileStore.ensureDirectoryExists()
        return tmp
    }

    private func tearDownBase(_ base: URL) {
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    private func writePNG(to url: URL) throws {
        let width = 8
        let height = 8
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context?.makeImage(),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw XCTSkip("Could not create test image")
        }
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testRetranscribeImageNoteKeepsFileAndMetadata() async throws {
        let base = try makeEnvIsolatedBase()
        defer { tearDownBase(base) }

        let note = FileStore.recordingsDirectory()
            .appendingPathComponent("Wimm_2026-07-24_18-13-06_D8FC8B.png")
        try writePNG(to: note)
        let metaURL = FileStore.metadataURL(forRecordingURL: note)
        let syncId = SyncRecordingID()
        try RecordingSyncMetadata.setSyncID(syncId, for: note, now: Date())

        let importer = DocumentImporter(ocrProvider: StubOCRProvider(text: "recognized text"))
        let ok = await importer.retranscribeDocument(at: note, processor: nil)

        XCTAssertTrue(ok, "OCR of an image note should succeed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: note.path),
            "re-processing must not delete the note file")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: metaURL.path),
            "re-processing must not delete the note metadata")

        let data = try Data(contentsOf: metaURL)
        let meta = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let document = meta[MetadataKey.document.rawValue] as? [String: Any]
        XCTAssertEqual(document?[MetadataKey.text.rawValue] as? String, "recognized text")
        XCTAssertEqual(
            RecordingSyncMetadata.readSyncID(for: note), syncId,
            "sync identity must survive re-processing")
    }
}
