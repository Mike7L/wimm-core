import XCTest
import WimmDomain
import WimmInfrastructure

final class DocumentTextBackfillServiceTests: XCTestCase {
    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmBackfillServiceTests_" + UUID().uuidString)
        setenv("WIMM_BASE_DIR", baseDir.path, 1)
        try? FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let baseDir {
            try? FileManager.default.removeItem(at: baseDir)
        }
        super.tearDown()
    }

    func testDryRunSkipsTxtWithExistingText() async {
        let file = FileStore.recordingsDirectory().appendingPathComponent("note.txt")
        try? "already has text".write(to: file, atomically: true, encoding: .utf8)

        let report = await DocumentTextBackfillService().run(
            DocumentTextBackfillRequest(apply: false)
        )

        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.skippedHasTextAlready, 1)
        XCTAssertEqual(report.extracted, 0)
        XCTAssertEqual(report.written, 0)
    }

    func testDryRunExtractsMarkdownDocuments() async {
        let file = FileStore.recordingsDirectory().appendingPathComponent("note.md")
        try? "# Title\n\nRecognized markdown body".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let report = await DocumentTextBackfillService().run(
            DocumentTextBackfillRequest(apply: false)
        )

        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.extracted, 1)
        XCTAssertEqual(report.providers[TextExtractionProvider.plainText], 1)
        XCTAssertEqual(report.written, 0)
    }

    func testDryRunWithoutOCRCountsImageAsEmpty() async {
        let file = FileStore.recordingsDirectory().appendingPathComponent("image.png")
        FileManager.default.createFile(atPath: file.path, contents: Data([1, 2, 3]))

        let report = await DocumentTextBackfillService().run(
            DocumentTextBackfillRequest(
                apply: false,
                ocr: false
            )
        )

        XCTAssertEqual(report.scanned, 1)
        XCTAssertEqual(report.emptyAfterExtraction, 1)
        XCTAssertEqual(report.extracted, 0)
        XCTAssertEqual(report.written, 0)
    }
}
