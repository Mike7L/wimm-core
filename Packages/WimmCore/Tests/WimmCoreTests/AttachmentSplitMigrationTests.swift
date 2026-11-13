import XCTest
@testable import WimmInfrastructure
@testable import WimmDomain

/// Stage 2 of docs/One_Note_One_Media_Decision_2026-11-09.md: every sidecar
/// attachment becomes a note of its own, dry-run first, resumable, idempotent.
final class AttachmentSplitMigrationTests: XCTestCase {
    private var library: URL!
    private var recordings: URL { library.appendingPathComponent("Recordings", isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        library = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("AttachmentSplit-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: library)
    }

    // MARK: - Fixtures

    private let imageID = "11111111-1111-1111-1111-111111111111"
    private let audioID = "22222222-2222-2222-2222-222222222222"
    private let missingID = "33333333-3333-3333-3333-333333333333"
    private let zipID = "44444444-4444-4444-4444-444444444444"
    private let outsideID = "55555555-5555-5555-5555-555555555555"

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func writeJSON(_ json: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// An Evernote-shaped `.txt` note with an image, an audio clip (+ `_micro`),
    /// a missing file, an unlisted type and a file outside the library. The
    /// image URL is written as another machine's absolute library path, the
    /// way real sidecars are, to prove it is mapped into this library.
    @discardableResult
    private func makeEvernoteParent() throws -> (txt: URL, sidecar: URL) {
        let folder = library.appendingPathComponent("Attachments/Evernote/E1", isDirectory: true)
        try write("jpeg", to: folder.appendingPathComponent("photo one.jpg"))
        try write("audio", to: folder.appendingPathComponent("clip.m4a"))
        try write("micro", to: folder.appendingPathComponent("clip_micro.m4a"))
        try write("zip", to: folder.appendingPathComponent("archive.zip"))
        let txt = recordings.appendingPathComponent("Wimm_2016-05-01_10-00-00_aaaaaaaa.txt")
        try write("# Trip\n\nLook:\n\n![photo one.jpg](Attachments/Evernote/E1/photo one.jpg)\n\nEnd.\n", to: txt)
        let foreignImage = "file:///Users/someone/Library/Application%20Support/Wimm/Attachments/Evernote/E1/photo%20one.jpg"
        let sidecar = recordings.appendingPathComponent("Wimm_2016-05-01_10-00-00_aaaaaaaa.meta.json")
        try writeJSON([
            "importSource": "Evernote",
            "evernoteId": "E1",
            "schema": "WimmMeta@v1",
            "attachments": [
                ["id": imageID, "url": foreignImage, "type": "image",
                 "extractedText": "sign text", "extractionProvider": "vision", "extractionModel": "VNRecognizeText",
                 "startedAt": "2026-10-28T21:30:24Z",
                 "imageAnalysis": ["source": "Attachments/Evernote/E1/photo one.jpg", "engine": "mlx"],
                 "previousRuns": [["text": "old ocr", "provider": "vision", "replacedAt": "2026-10-29T00:00:00Z"]]],
                ["id": audioID, "url": folder.appendingPathComponent("clip.m4a").absoluteString, "type": "audio",
                 "extractedText": "hello there", "extractionProvider": "gemini", "extractionModel": "gemini-3-flash",
                 "previousRuns": [["text": "helo", "provider": "parakeet", "replacedAt": "2026-10-20T00:00:00Z"]]],
                ["id": missingID, "url": "Attachments/Evernote/E1/gone.png", "type": "image"],
                ["id": zipID, "url": folder.appendingPathComponent("archive.zip").absoluteString, "type": "file"],
                ["id": outsideID, "url": "file:///private/var/mobile/x.heic", "type": "image"],
            ],
        ], to: sidecar)
        return (txt, sidecar)
    }

    private func listing() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = fm.enumerator(at: library, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                result[String(url.path.dropFirst(library.path.count))] = try Data(contentsOf: url)
            }
        }
        return result
    }

    private func run(apply: Bool) throws -> AttachmentSplitMigration.Report {
        try AttachmentSplitMigration.run(.init(
            apply: apply,
            backupDirectory: apply ? library.appendingPathComponent("repair-backups/split-test") : nil,
            library: library))
    }

    // MARK: - Tests

    func testDryRunChangesNothingAndReportsThePlan() throws {
        try makeEvernoteParent()
        let before = try listing()

        let report = try run(apply: false)

        XCTAssertEqual(try listing(), before, "a dry run must not write a byte")
        XCTAssertTrue(report.dryRun)
        let items = try XCTUnwrap(report.parents.first?.items)
        XCTAssertEqual(items.map(\.action), ["split", "split", "missing", "unsupported", "outside-library"])
        XCTAssertEqual(items[0].link, "replaced")
        XCTAssertEqual(items[1].link, "appended")
        XCTAssertTrue(try XCTUnwrap(items[0].target).hasPrefix("Recordings/Wimm_2016-05-01_10-00-01_"))
        XCTAssertTrue(try XCTUnwrap(items[1].target).hasPrefix("Recordings/Wimm_2016-05-01_10-00-02_"))
        XCTAssertEqual(report.totals.byAction["split"], 2)
        XCTAssertNotNil(items[1].micro, "the planned _micro move shows in the dry run")
        XCTAssertEqual(report.totals.microMoved, 1)
    }

    func testApplySplitsCarriesTextLinksAndKeepsWhatItCannotMove() throws {
        let parent = try makeEvernoteParent()
        let plan = try run(apply: false)

        let report = try run(apply: true)
        XCTAssertEqual(report.totals.parentsFailed, 0)
        let items = try XCTUnwrap(report.parents.first?.items)
        // The dry run predicted exactly what was done.
        XCTAssertEqual(items.map(\.target), plan.parents.first?.items.map(\.target))

        let image = library.appendingPathComponent(try XCTUnwrap(items[0].target))
        let audio = library.appendingPathComponent(try XCTUnwrap(items[1].target))
        XCTAssertEqual(try String(contentsOf: image, encoding: .utf8), "jpeg")
        XCTAssertEqual(try String(contentsOf: audio, encoding: .utf8), "audio")
        XCTAssertFalse(fm.fileExists(atPath: library.appendingPathComponent("Attachments/Evernote/E1/photo one.jpg").path),
                       "media is moved, not copied")
        XCTAssertEqual(try String(contentsOf: FileStore.microURL(forRecordingURL: audio), encoding: .utf8), "micro")
        XCTAssertNotNil(items[1].micro)

        let imageMeta = try readJSON(FileStore.metadataURL(forRecordingURL: image))
        XCTAssertNil(imageMeta["attachments"])
        XCTAssertNil(imageMeta["evernoteId"], "only the parent keeps the Evernote id the importer dedups on")
        XCTAssertEqual(imageMeta["importSource"] as? String, "Evernote")
        let split = try XCTUnwrap(imageMeta["splitFrom"] as? [String: Any])
        XCTAssertEqual(split["parentSidecar"] as? String, parent.sidecar.lastPathComponent)
        XCTAssertEqual(split["attachmentID"] as? String, imageID)
        let ocr = try XCTUnwrap(imageMeta["ocr"] as? [String: Any])
        XCTAssertEqual(ocr["text"] as? String, "sign text")
        XCTAssertEqual((ocr["previousRuns"] as? [[String: Any]])?.first?["text"] as? String, "old ocr")
        XCTAssertEqual((ocr["imageAnalysis"] as? [String: Any])?["source"] as? String, items[0].target)
        XCTAssertEqual((imageMeta["document"] as? [String: Any])?["text"] as? String, "sign text")
        XCTAssertNotNil(imageMeta[RecordingIdentity.metadataKey])

        let audioMeta = try readJSON(FileStore.metadataURL(forRecordingURL: audio))
        let transcription = try XCTUnwrap(audioMeta["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["transcript"] as? String, "hello there")
        XCTAssertEqual(transcription["provider"] as? String, "gemini")
        XCTAssertEqual(transcription["speechStatus"] as? String, "speech")
        XCTAssertEqual((transcription["previousRuns"] as? [[String: Any]])?.first?["transcript"] as? String, "helo")

        let body = try String(contentsOf: parent.txt, encoding: .utf8)
        let imageBase = image.deletingPathExtension().lastPathComponent
        let audioBase = audio.deletingPathExtension().lastPathComponent
        XCTAssertTrue(body.contains("Look:\n\n[[\(imageBase)]]\n\nEnd."), body)
        XCTAssertTrue(body.hasSuffix("End.\n\n[[\(audioBase)]]\n"), body)

        let parentMeta = try readJSON(parent.sidecar)
        let left = try XCTUnwrap(parentMeta["attachments"] as? [[String: Any]])
        XCTAssertEqual(left.compactMap { $0["id"] as? String }, [missingID, zipID, outsideID])
        XCTAssertEqual(parentMeta["evernoteId"] as? String, "E1")

        let backups = library.appendingPathComponent("repair-backups/split-test")
        XCTAssertTrue(fm.fileExists(atPath: backups.appendingPathComponent(parent.sidecar.lastPathComponent).path))
        XCTAssertTrue(fm.fileExists(atPath: backups.appendingPathComponent(parent.txt.lastPathComponent).path))

        // The new notes are listed as notes; the parent still is.
        let listed = Set((try fm.contentsOfDirectory(atPath: recordings.path)).filter { !$0.hasSuffix(".json") })
        XCTAssertTrue(listed.isSuperset(of: [image.lastPathComponent, audio.lastPathComponent, parent.txt.lastPathComponent]))
    }

    func testSecondApplyChangesNothing() throws {
        try makeEvernoteParent()
        _ = try run(apply: true)
        let after = try listing().filter { !$0.key.hasPrefix("/repair-backups") }

        let again = try run(apply: true)

        XCTAssertEqual(try listing().filter { !$0.key.hasPrefix("/repair-backups") }, after)
        XCTAssertNil(again.totals.byAction["split"])
        XCTAssertEqual(again.parents.first?.items.map(\.action), ["missing", "unsupported", "outside-library"])
    }

    func testInterruptedRunResumesWithoutDuplicates() throws {
        let parent = try makeEvernoteParent()
        let original = try readJSON(parent.sidecar)
        _ = try run(apply: true)
        let firstNotes = try fm.contentsOfDirectory(atPath: recordings.path).sorted()
        // As if the run stopped after moving the files but before the parent was updated.
        try writeJSON(original, to: parent.sidecar)

        let report = try run(apply: true)

        XCTAssertEqual(report.parents.first?.items.prefix(2).map(\.action), ["resume", "resume"])
        XCTAssertEqual(report.parents.first?.items.prefix(2).map(\.link), ["present", "present"])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: recordings.path).sorted(), firstNotes)
        let left = try XCTUnwrap(try readJSON(parent.sidecar)["attachments"] as? [[String: Any]])
        XCTAssertEqual(left.count, 3)
    }

    func testParentWithoutMediaTakesItsFirstAttachmentAsItsFile() throws {
        let base = "2024.02.24 Continentale"
        try write("heic", to: recordings.appendingPathComponent("\(base)_Attach_0.heic"))
        try write("pdf", to: recordings.appendingPathComponent("\(base)_Attach_0.pdf"))
        let sidecar = recordings.appendingPathComponent("\(base).meta.json")
        try writeJSON([
            "createdAt": "2024-02-24T10:00:00Z",
            "attachments": [
                ["id": imageID, "url": recordings.appendingPathComponent("\(base)_Attach_0.heic").absoluteString,
                 "type": "image", "extractedText": "Continentale", "extractionProvider": "vision"],
                ["id": audioID, "url": recordings.appendingPathComponent("\(base)_Attach_0.pdf").absoluteString,
                 "type": "pdf"],
            ],
        ], to: sidecar)

        let report = try run(apply: true)

        XCTAssertEqual(report.parents.first?.items.map(\.action), ["promote", "split"])
        XCTAssertEqual(try String(contentsOf: recordings.appendingPathComponent("\(base).heic"), encoding: .utf8), "heic")
        let meta = try readJSON(sidecar)
        XCTAssertNil(meta["attachments"])
        XCTAssertEqual((meta["ocr"] as? [String: Any])?["text"] as? String, "Continentale")
        XCTAssertEqual((meta[AttachmentSplitMigration.promotedKey] as? [String: Any])?["attachmentID"] as? String, imageID)
        let pdf = library.appendingPathComponent(try XCTUnwrap(report.parents.first?.items[1].target))
        XCTAssertTrue(pdf.lastPathComponent.hasPrefix("Wimm_2024-02-24_"), pdf.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: pdf, encoding: .utf8), "pdf")
        XCTAssertEqual(report.parents.first?.items[1].link, "non-text-parent")
    }

    func testEveningAnswerGoesUnderItsQuestionAndEmptyListsAreDropped() throws {
        let base = "Wimm_2026-11-01_19-57-05_9C23FC5A"
        let md = recordings.appendingPathComponent("\(base).md")
        try write("# Вечер\n\n## Что удивило?\n\nответ\n\n## Мысли\n\nмысль\n", to: md)
        let answer = library.appendingPathComponent("Attachments/Journal/\(base)/answer-1.aac")
        try write("aac", to: answer)
        let sidecar = recordings.appendingPathComponent("\(base).meta.json")
        try writeJSON(["journal": ["date": "2026-11-01"], "attachments": [
            ["id": imageID, "url": "Attachments/Journal/\(base)/answer-1.aac", "type": "audio",
             "journalPrompt": "Что удивило?", "extractedText": "ответ", "extractionProvider": "parakeet"],
        ]], to: sidecar)
        let empty = recordings.appendingPathComponent("Wimm_2026-01-01_00-00-00_bbbbbbbb.meta.json")
        try write("x", to: recordings.appendingPathComponent("Wimm_2026-01-01_00-00-00_bbbbbbbb.m4a"))
        try writeJSON(["attachments": [Any]()], to: empty)

        let report = try run(apply: true)

        let item = try XCTUnwrap(report.parents.first { $0.sidecar == sidecar.lastPathComponent }?.items.first)
        let child = library.appendingPathComponent(try XCTUnwrap(item.target)).deletingPathExtension().lastPathComponent
        let body = try String(contentsOf: md, encoding: .utf8)
        XCTAssertTrue(body.contains("ответ\n\n[голос](\(child).meta.json)\n\n## Мысли"), body)
        let childMeta = try readJSON(recordings.appendingPathComponent("\(child).meta.json"))
        XCTAssertEqual((childMeta["origin"] as? [String: Any])?["journalPrompt"] as? String, "Что удивило?")
        XCTAssertFalse(fm.fileExists(atPath: library.appendingPathComponent("Attachments/Journal/\(base)").path),
                       "the emptied answer folder goes")
        XCTAssertNil(try readJSON(empty)["attachments"])
        XCTAssertEqual(report.totals.emptyLists, 1)
    }

    func testApplyWithoutBackupIsRefused() {
        XCTAssertThrowsError(try AttachmentSplitMigration.run(.init(apply: true, library: library)))
    }
}
