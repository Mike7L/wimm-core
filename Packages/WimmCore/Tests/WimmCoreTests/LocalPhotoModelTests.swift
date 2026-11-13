import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import WimmInfrastructure

final class LocalPhotoModelTests: XCTestCase {
    func testPackagedWorkerIsPreferredOverCheckoutResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let app = root.appendingPathComponent("Fixture.app")
        let resources = app.appendingPathComponent("Contents/Resources/WimmCore_WimmInfrastructure.bundle")
        try FileManager.default.createDirectory(at:resources,withIntermediateDirectories:true)
        let plist: [String:Any] = ["CFBundleIdentifier":"test.wimm.image-worker","CFBundlePackageType":"APPL","CFBundleName":"Fixture"]
        try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
        let worker = resources.appendingPathComponent("mlx_photo_worker.py")
        try Data("# packaged worker fixture".utf8).write(to:worker)
        let bundle = try XCTUnwrap(Bundle(url:app))
        XCTAssertEqual(LocalPhotoModel.workerURL(in:bundle)?.standardizedFileURL,worker.standardizedFileURL)
    }
    private func response(_ overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["caption": "A blue cup on a table.", "seconds": 1.5,
            "peak_memory_gb": 1.6, "generation_tokens": 12, "finish_reason": "stop"]
        value.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testAcceptsFinishedCaptionAndMetrics() throws {
        let value = try LocalPhotoModel.decode(response())
        XCTAssertEqual(value.caption, "A blue cup on a table.")
        XCTAssertEqual(value.peakMemoryGB, 1.6)
    }
    func testRejectsClippedEmptyAndOversizedOutputs() throws {
        for bad in [["finish_reason": "length"], ["caption": "  "], ["caption": String(repeating: "x", count: 2001)],
                    ["generation_tokens": 129], ["seconds": -1]] as [[String: Any]] {
            XCTAssertThrowsError(try LocalPhotoModel.decode(response(bad)))
        }
        XCTAssertThrowsError(try LocalPhotoModel.decode(Data(repeating: 32, count: 16_385)))
        XCTAssertThrowsError(try LocalPhotoModel.decode(Data("{\"error\":\"ValueError\"}".utf8)))
    }
    func testKeepsOCRVerbatimAndLabelsCaptionAsDraft() {
        let original = "Анне 150 евро НЕ переводил.\nЦена: 12,50 EUR"
        let output = LocalPhotoOCRProvider.combine(caption: "A printed page.", text: original)
        XCTAssertTrue(output.hasPrefix("[image description (local MLX, draft):"))
        XCTAssertTrue(output.hasSuffix(original))
        XCTAssertFalse(output.contains("[scene:"))
    }
    func testSamplerReturnsDistinctFilesInCaptureOrder() {
        let note = URL(fileURLWithPath: "/test/note.txt"), first = URL(fileURLWithPath: "/test/first.jpg"), second = URL(fileURLWithPath: "/test/second.jpg")
        let rows = [PhotoLibrarySampler.Target(note: note, image: first, date: Date(timeIntervalSince1970: 1), dateBasis: "test"),
                    PhotoLibrarySampler.Target(note: note, image: second, date: Date(timeIntervalSince1970: 2), dateBasis: "test"),
                    PhotoLibrarySampler.Target(note: note, image: second, date: Date(timeIntervalSince1970: 3), dateBasis: "test")]
        XCTAssertEqual(PhotoLibrarySampler.select(rows, limit: 2).map(\.image), [second, first])
        XCTAssertEqual(PhotoLibrarySampler.select(rows, limit: 1).count, 1)
        XCTAssertTrue(PhotoLibrarySampler.select(rows, limit: 0).isEmpty)
    }
    func testInputAppliesOrientationAndBoundsDecode() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rotated.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 40, bitsPerComponent: 8, bytesPerRow: 320,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try LocalPhotoInput.load(url, maximumSide: 40)
        XCTAssertEqual(decoded.width, 20); XCTAssertEqual(decoded.height, 40)
        XCTAssertThrowsError(try LocalPhotoInput.load(URL(string: "https://example.com/image.png")!))
        XCTAssertThrowsError(try LocalPhotoInput.load(url, maximumSide: 0))
    }
    func testRealInferenceRefusesTestProcess() async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        do {
            _ = try await LocalPhotoModel.describe(image: XCTUnwrap(context.makeImage()))
            XCTFail("Tests must not launch a real model")
        } catch { XCTAssertTrue(error is LocalPhotoModel.Failure) }
    }
}
