import XCTest
import WimmDomain
import WimmInfrastructure
import CryptoKit

final class HeadlessImportServiceTests: XCTestCase {
    private var baseDir: URL!

    override func setUp() {
        super.setUp()
        baseDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmHeadlessImportTests_" + UUID().uuidString)
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

    func testDryRunSummary() async throws {
        let inputDir = baseDir.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        let txt = inputDir.appendingPathComponent("note.txt")
        let pdf = inputDir.appendingPathComponent("doc.pdf")
        let other = inputDir.appendingPathComponent("blob.bin")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: pdf)
        try Data([7, 8, 9]).write(to: other)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(inputPaths: [inputDir.path], dryRun: true)
        )

        XCTAssertEqual(report.found, 3)
        XCTAssertEqual(report.importable, 2)
        XCTAssertEqual(report.wouldImport, 2)
        XCTAssertEqual(report.imported, 0)
        XCTAssertEqual(report.unsupported, 1)
        XCTAssertEqual(report.duplicates, 0)
    }

    func testDuplicateDetectionIncludesExistingAndSelectionDuplicates() async throws {
        let recordings = FileStore.recordingsDirectory()
        let existing = recordings.appendingPathComponent("existing.txt")
        try "same-as-existing".write(to: existing, atomically: true, encoding: .utf8)

        let inputDir = baseDir.appendingPathComponent("dups")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)

        let dupExisting = inputDir.appendingPathComponent("dup_existing.txt")
        let uniqueA = inputDir.appendingPathComponent("unique_a.txt")
        let uniqueB = inputDir.appendingPathComponent("unique_b.txt")
        try "same-as-existing".write(to: dupExisting, atomically: true, encoding: .utf8)
        try "shared-selection".write(to: uniqueA, atomically: true, encoding: .utf8)
        try "shared-selection".write(to: uniqueB, atomically: true, encoding: .utf8)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(inputPaths: [inputDir.path], dryRun: true)
        )

        XCTAssertEqual(report.importable, 3)
        XCTAssertEqual(report.duplicates, 2)
        XCTAssertEqual(report.wouldImport, 1)
        XCTAssertTrue(report.duplicateDetails.contains { $0.reason == .alreadyImported })
        XCTAssertTrue(report.duplicateDetails.contains { $0.reason == .duplicateInSelection })
    }

    func testImportCopiesFileAndWritesSourceMetadata() async throws {
        let inputDir = baseDir.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let source = inputDir.appendingPathComponent("import_me.txt")
        try "payload".write(to: source, atomically: true, encoding: .utf8)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(inputPaths: [source.path], dryRun: false)
        )

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.importedPaths.count, 1)

        let importedURL = URL(fileURLWithPath: report.importedPaths[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))

        let metaURL = FileStore.metadataURL(forRecordingURL: importedURL)
        let metaData = try Data(contentsOf: metaURL)
        let json = try JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        XCTAssertEqual(json?[MetadataKey.sourcePath.rawValue] as? String, source.path)
    }

    func testImportWithBackfillWritesDocumentText() async throws {
        let inputDir = baseDir.appendingPathComponent("backfill")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let source = inputDir.appendingPathComponent("note.txt")
        try "backfill me".write(to: source, atomically: true, encoding: .utf8)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(
                inputPaths: [source.path],
                dryRun: false,
                backfillText: true
            )
        )

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.backfilled, 1)
        XCTAssertEqual(report.backfillFailed, 0)

        let importedURL = URL(fileURLWithPath: try XCTUnwrap(report.importedPaths.first))
        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: importedURL))
        ) as? [String: Any]
        let document = metadata?[MetadataKey.document.rawValue] as? [String: Any]
        XCTAssertEqual(document?[MetadataKey.text.rawValue] as? String, "backfill me")
        XCTAssertEqual(document?[MetadataKey.textProvider.rawValue] as? String, TextExtractionProvider.plainText)
        XCTAssertNil(document?[MetadataKey.textModel.rawValue], "Plain text extraction should not set model")
    }

    func testImportPDFWithBackfillStoresOCRProviderModel() async throws {
        let inputDir = baseDir.appendingPathComponent("backfill_pdf")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let source = inputDir.appendingPathComponent("no_text.pdf")
        try FileManager.default.copyItem(at: try loadNoTextPDFFixture(), to: source)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(
                inputPaths: [source.path],
                dryRun: false,
                backfillText: true,
                maxPDFOCRPages: 1
            )
        )

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.backfilled, 1)
        XCTAssertEqual(report.backfillFailed, 0)

        let importedURL = URL(fileURLWithPath: try XCTUnwrap(report.importedPaths.first))
        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: importedURL))
        ) as? [String: Any]
        let document = try XCTUnwrap(metadata?[MetadataKey.document.rawValue] as? [String: Any])
        let text = (document[MetadataKey.text.rawValue] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse((text ?? "").isEmpty)
        XCTAssertEqual(document[MetadataKey.textProvider.rawValue] as? String, TextExtractionProvider.vision)
        XCTAssertEqual(document[MetadataKey.textModel.rawValue] as? String, "VNRecognizeText")
    }

    func testDryRunENEXCountsNotes() async throws {
        let inputDir = baseDir.appendingPathComponent("enex_dry")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let enexURL = inputDir.appendingPathComponent("sample.enex")

        let payload = Data("image-data".utf8)
        let hash = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let b64 = payload.base64EncodedString()
        let enex = """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export>
          <note>
            <title>First Note</title>
            <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>Hello <b>world</b> <en-media type="image/png" hash="\(hash)"/></en-note>]]></content>
            <created>20260206T120000Z</created>
            <resource>
              <data encoding="base64">\(b64)</data>
              <mime>image/png</mime>
              <resource-attributes><file-name>shot.png</file-name></resource-attributes>
            </resource>
          </note>
          <note>
            <title>Second Note</title>
            <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><en-note>Second body</en-note>]]></content>
            <created>20260206T130000Z</created>
          </note>
        </en-export>
        """
        try enex.write(to: enexURL, atomically: true, encoding: .utf8)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(inputPaths: [enexURL.path], dryRun: true)
        )

        XCTAssertEqual(report.found, 1)
        XCTAssertEqual(report.importable, 1)
        XCTAssertEqual(report.wouldImport, 2)
        XCTAssertEqual(report.imported, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.kindCounts["enex"], 2)
    }

    func testImportENEXCreatesNotesAttachmentsAndMetadata() async throws {
        let inputDir = baseDir.appendingPathComponent("enex_real")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let enexURL = inputDir.appendingPathComponent("real.enex")

        let payload = Data("image-data".utf8)
        let hash = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let b64 = payload.base64EncodedString()
        let enex = """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export>
          <note>
            <title>ENEX One</title>
            <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><en-note>Body <en-media type="image/png" hash="\(hash)"/></en-note>]]></content>
            <created>20260206T120000Z</created>
            <updated>20260206T121000Z</updated>
            <tag>tag-a</tag>
            <resource>
              <data encoding="base64">\(b64)</data>
              <mime>image/png</mime>
              <resource-attributes><file-name>clip.png</file-name></resource-attributes>
            </resource>
          </note>
        </en-export>
        """
        try enex.write(to: enexURL, atomically: true, encoding: .utf8)

        let report = try await HeadlessImportService().run(
            HeadlessImportRequest(inputPaths: [enexURL.path], dryRun: false)
        )

        XCTAssertEqual(report.imported, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(report.kindCounts["enex"], 1)
        XCTAssertEqual(report.importedPaths.count, 1)

        let noteURL = URL(fileURLWithPath: try XCTUnwrap(report.importedPaths.first))
        XCTAssertEqual(noteURL.pathExtension.lowercased(), "txt")
        let text = try String(contentsOf: noteURL, encoding: .utf8)
        XCTAssertTrue(text.contains("ENEX One"))
        XCTAssertTrue(text.contains("Body"))
        XCTAssertTrue(text.contains("Attachment"))

        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: noteURL))
        ) as? [String: Any]
        XCTAssertEqual(metadata?[MetadataKey.sourcePath.rawValue] as? String, enexURL.path)
        let document = metadata?[MetadataKey.document.rawValue] as? [String: Any]
        XCTAssertEqual(document?["sourceType"] as? String, "enex")

        let attachments = await AttachmentRepository(metadataRepository: MetadataRepository()).attachments(for: noteURL)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachments[0].url.path))
    }

    private func loadNoTextPDFFixture() throws -> URL {
        if let url = Bundle.module.url(forResource: "no_text", withExtension: "pdf") {
            return url
        }
        let currentFile = URL(fileURLWithPath: #filePath)
        let fallback = currentFile.deletingLastPathComponent().appendingPathComponent(
            "Resources/no_text.pdf"
        )
        guard FileManager.default.fileExists(atPath: fallback.path) else {
            throw NSError(
                domain: "HeadlessImportServiceTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Fixture not found: \(fallback.path)"]
            )
        }
        return fallback
    }
}
