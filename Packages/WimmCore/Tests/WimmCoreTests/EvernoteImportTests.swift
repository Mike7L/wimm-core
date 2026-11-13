import XCTest
@testable import WimmInfrastructure
@testable import WimmDomain

final class EvernoteImportTests: XCTestCase {

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sample.enex")
    }

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvernoteImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An imported note as it lands on disk: the `.txt` body plus its sidecar dict.
    private struct ImportedNote {
        let text: String
        let meta: [String: Any]
        let url: URL
        /// Date recovered from the `Wimm_<yyyy-MM-dd_HH-mm-ss>_...` filename, mirroring
        /// `FileStore.recordingDateFromFileName` (the meta `createdAt` is intentionally
        /// stripped by `sanitizeMetaJSONUpdates`; the filename is the source of truth).
        var createdAt: Date? {
            let base = url.deletingPathExtension().lastPathComponent
            guard base.hasPrefix("Wimm_") else { return nil }
            let stamp = String(base.dropFirst("Wimm_".count).prefix(19))
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            return f.date(from: stamp)
        }
        var evernoteId: String? { meta["evernoteId"] as? String }
        var processingStatus: String? { meta["processingStatus"] as? String }
    }

    /// Loads every imported `.txt` note (with its sidecar) from a storage root.
    private func loadImported(in root: URL) -> [ImportedNote] {
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil) else { return [] }

        return files.filter { $0.pathExtension == "txt" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let metaURL = url.deletingPathExtension().appendingPathExtension("meta.json")
            let meta = (try? Data(contentsOf: metaURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return ImportedNote(text: text, meta: meta, url: url)
        }
    }

    func testImportsNotesWithAttachmentsAndDates() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let importer = EvernoteImporter(storageRoot: root)
        let summary = try await importer.importENEX(at: [fixtureURL()])

        XCTAssertEqual(summary.found, 2)
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.skipped, 0)
        XCTAssertEqual(summary.attachments, 1)
        XCTAssertEqual(summary.failed, 0)

        let notes = loadImported(in: root).sorted {
            ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
        }
        XCTAssertEqual(notes.count, 2)

        // First note: 2018 created date preserved, title heading, resolved link, code block, attachment link.
        let first = notes[0]
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(cal.component(.year, from: try XCTUnwrap(first.createdAt)), 2018)
        XCTAssertEqual(first.processingStatus, "pending")
        XCTAssertTrue(first.text.contains("# Test Idea"), first.text)
        XCTAssertTrue(first.text.contains("[example](https://example.com)"), first.text)
        XCTAssertTrue(first.text.contains("Hello & welcome"), first.text)
        XCTAssertTrue(first.text.contains("```"), first.text)
        // One note = one media (2026-11-09): the attachment is its own note,
        // linked from the text where the Markdown image used to point.
        XCTAssertNil(first.meta["attachments"], "a new import never leaves sidecar attachments")
        XCTAssertFalse(first.text.contains("Attachments/Evernote/"), first.text)
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let pngs = try FileManager.default.contentsOfDirectory(atPath: recordings.path).filter { $0.hasSuffix(".png") }
        XCTAssertEqual(pngs.count, 1)
        let image = recordings.appendingPathComponent(try XCTUnwrap(pngs.first))
        XCTAssertTrue(first.text.contains("[[\(image.deletingPathExtension().lastPathComponent)]]"), first.text)
        let size = (try? FileManager.default.attributesOfItem(atPath: image.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
        let imageMeta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: image))) as? [String: Any])
        XCTAssertNil(imageMeta["attachments"])
        XCTAssertNil(imageMeta["evernoteId"], "only the text note carries the id re-import dedups on")
        XCTAssertEqual((imageMeta["splitFrom"] as? [String: Any])?["parentSidecar"] as? String,
                       first.url.deletingPathExtension().appendingPathExtension("meta.json").lastPathComponent)
        XCTAssertNotNil(first.evernoteId)

        let second = notes[1]
        XCTAssertEqual(cal.component(.year, from: try XCTUnwrap(second.createdAt)), 2020)
        XCTAssertTrue(second.text.contains("Just text, no attachments."), second.text)
    }

    func testReimportIsIdempotent() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let importer = EvernoteImporter(storageRoot: root)
        _ = try await importer.importENEX(at: [fixtureURL()])
        let second = try await importer.importENEX(at: [fixtureURL()])

        XCTAssertEqual(second.found, 2)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.skipped, 2)

        XCTAssertEqual(loadImported(in: root).count, 2, "Re-import must not duplicate notes")
    }

    func testDryRunWritesNothing() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let importer = EvernoteImporter(storageRoot: root)
        let summary = try await importer.importENEX(at: [fixtureURL()], dryRun: true)
        XCTAssertEqual(summary.found, 2)
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.attachments, 0)

        XCTAssertTrue(loadImported(in: root).isEmpty, "Dry run must not persist notes")
        let attachRoot = root.appendingPathComponent("Attachments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachRoot.path))
    }

    func testAttachmentFileNameFallsBackWhenPreferredNameIsTooLong() {
        // Some Evernote exports carry a webmail URL as the resource's "file-name"
        // (e.g. a forwarded Gmail attachment) instead of a real file name — the
        // sanitizer only strips path-breaking characters, so an overlong name
        // must fall back to the synthetic form rather than fail the disk write.
        let overlong = "attachment?ui=2&ik=abc123&attid=0.1&" + String(repeating: "x", count: 250)
        let name = ENEXParser.attachmentFileName(
            preferred: overlong, mime: "audio/mp4", md5: "deadbeef00112233", index: 3)
        XCTAssertEqual(name, "attachment_3_deadbeef.m4a")

        // A normal, short file name is left untouched.
        let normal = ENEXParser.attachmentFileName(
            preferred: "Recording (1).m4a", mime: "audio/mp4", md5: "deadbeef", index: 0)
        XCTAssertEqual(normal, "Recording__1_.m4a")
    }

    func testENMLToMarkdownLinkAndCodeblock() {
        let enml = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">
        <en-note><div>Visit <a href="https://x.io">X</a></div>\
        <div style="-en-codeblock:true;"><div>code here</div></div></en-note>
        """
        let md = ENMLToMarkdown.convert(enml: enml, attachments: [:])
        XCTAssertTrue(md.contains("[X](https://x.io)"), md)
        XCTAssertTrue(md.contains("```"), md)
        XCTAssertTrue(md.contains("code here"), md)
    }
}
