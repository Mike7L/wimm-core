import XCTest
@testable import WimmInfrastructure
@testable import WimmDomain

/// 2026-11-21: attachments the library cannot list become PNG, m4a or text
/// next to the original (which stays), then split like any other.
final class AttachmentConversionTests: XCTestCase {
    private var library: URL!
    private var recordings: URL { library.appendingPathComponent("Recordings", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        library = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AttachmentConversion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: library) }

    private let fake = AttachmentConversion.Converter(
        svgToPNG: { _, output in try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: output) },
        audioToM4A: { _, _ in throw CocoaError(.fileReadUnknown) },
        htmlToText: { _ in "Заголовок статьи\nТекст статьи" },
        zipListing: { _ in "a.txt\nb.png" }
    )

    func testUnsupportedAttachmentsBecomeListedFilesAndSplit() throws {
        let folder = library.appendingPathComponent("Attachments/Evernote/E9", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let svg = folder.appendingPathComponent("logo.svg")
        let page = folder.appendingPathComponent("08.05.2015_2")
        let voice = folder.appendingPathComponent("26.04.2015_09:15:29")
        try Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8).write(to: svg)
        try Data("<!DOCTYPE html><html><body>x</body></html>".utf8).write(to: page)
        try Data("#!AMR\n....".utf8).write(to: voice)
        let txt = recordings.appendingPathComponent("Wimm_2015-05-08_10-00-00_cccccccc.txt")
        try Data("Смотри:\n\n![logo.svg](Attachments/Evernote/E9/logo.svg)\n".utf8).write(to: txt)
        let ids = ["88888888-8888-8888-8888-888888888888", "99999999-9999-9999-9999-999999999999",
                   "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        let sidecar = FileStore.metadataURL(forRecordingURL: txt)
        try JSONSerialization.data(withJSONObject: [
            "importSource": "Evernote", "schema": "WimmMeta@v1",
            "attachments": [
                ["id": ids[0], "url": svg.absoluteString, "type": "file"],
                ["id": ids[1], "url": page.absoluteString, "type": "file"],
                ["id": ids[2], "url": voice.absoluteString, "type": "file"],
            ],
        ]).write(to: sidecar)

        let dry = try AttachmentConversion.run(library: library, apply: false, converter: fake)
        XCTAssertEqual(dry.items.map(\.format), [.svg, .html, .amr])
        XCTAssertFalse(fm.fileExists(atPath: svg.path + ".png"), "a dry run writes nothing")

        let applied = try AttachmentConversion.run(library: library, apply: true, converter: fake)
        XCTAssertEqual(applied.items.map(\.action), ["convert", "convert", "describe"])
        XCTAssertTrue(fm.fileExists(atPath: svg.path), "the original stays")
        let pageText = try String(contentsOf: URL(fileURLWithPath: page.path + ".txt"), encoding: .utf8)
        XCTAssertTrue(pageText.contains("Текст статьи"), pageText)
        let voiceText = try String(contentsOf: URL(fileURLWithPath: voice.path + ".txt"), encoding: .utf8)
        XCTAssertTrue(voiceText.contains("голосовая запись AMR"), voiceText)

        // A rerun reuses what exists.
        XCTAssertEqual(try AttachmentConversion.run(library: library, apply: false, converter: fake).items.count, 0,
                       "converted entries are no longer unsupported")

        let split = try AttachmentSplitMigration.run(.init(
            apply: true, backupDirectory: library.appendingPathComponent("repair-backups/t"), library: library))
        let items = try XCTUnwrap(split.parents.first?.items)
        XCTAssertEqual(items.map(\.action), ["split", "split", "split"])
        XCTAssertEqual(items.compactMap { $0.target.map { ($0 as NSString).pathExtension } }, ["png", "txt", "txt"])
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertNil(meta["attachments"])
        let body = try String(contentsOf: txt, encoding: .utf8)
        let pngBase = (try XCTUnwrap(items[0].target) as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
        XCTAssertTrue(body.contains("[[\(pngBase)]]"), "the link to the original SVG is replaced: \(body)")
        XCTAssertFalse(body.contains("logo.svg)"), body)
    }

    func testLostAttachmentBecomesATextThatSaysSo() throws {
        let txt = recordings.appendingPathComponent("Wimm_2016-01-02_10-00-00_dddddddd.txt")
        try Data("Скриншот ниже\n".utf8).write(to: txt)
        let sidecar = FileStore.metadataURL(forRecordingURL: txt)
        let id = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
        try JSONSerialization.data(withJSONObject: [
            "schema": "WimmMeta@v1",
            "attachments": [["id": id, "url": "Recordings/screenshot_gone.png", "type": "image"]],
        ]).write(to: sidecar)

        let report = try AttachmentConversion.run(library: library, apply: true, converter: fake)
        XCTAssertEqual(report.items.map(\.format), [.lost])
        let lost = library.appendingPathComponent("Attachments/Lost/\(id).txt")
        XCTAssertTrue(try String(contentsOf: lost, encoding: .utf8).contains("screenshot_gone.png"))

        let split = try AttachmentSplitMigration.run(.init(
            apply: true, backupDirectory: library.appendingPathComponent("repair-backups/l"), library: library))
        XCTAssertEqual(split.parents.first?.items.map(\.action), ["split"])
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertNil(meta["attachments"], "no attachment is left behind")
    }
}
