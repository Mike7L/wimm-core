import XCTest
import WimmDomain
import WimmInfrastructure

final class AudioImportServiceTests: XCTestCase {
    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmAudioImportTests_" + UUID().uuidString)
        setenv("WIMM_BASE_DIR", baseDir.path, 1)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let baseDir {
            try? FileManager.default.removeItem(at: baseDir)
        }
        super.tearDown()
    }

    func testImportBatchCopiesAudioAndWritesSourceMetadata() async throws {
        let inputDir = baseDir.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let source = inputDir.appendingPathComponent("sample.m4a")
        try Data("audio".utf8).write(to: source)

        let summary = await AudioImportService().importBatch(urls: [source])
        XCTAssertEqual(summary.found, 1)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.importedPaths.count, 1)

        let importedURL = URL(fileURLWithPath: summary.importedPaths[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))

        let metadataURL = FileStore.metadataURL(forRecordingURL: importedURL)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        XCTAssertEqual(json?[MetadataKey.sourcePath.rawValue] as? String, source.path)
    }

}
