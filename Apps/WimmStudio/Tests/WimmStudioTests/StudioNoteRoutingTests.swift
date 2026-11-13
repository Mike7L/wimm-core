import AppKit
import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class StudioNoteRoutingTests: XCTestCase {
    private func entry(_ file: URL) -> StudioLibraryNote {
        StudioLibraryNote(Note(id: UUID(), index: 0, fileURL: file, fileCreated: Date(), start: 0, end: 0,
                               text: "Заметка", isFailed: false, hasRaw: false, title: "Источник"))
    }

    func testOriginalAndSidecarLinksResolveToTheSameNoteIncludingFragments() throws {
        let note = entry(URL(fileURLWithPath: "/tmp/studio-routing/заметка с пробелами.m4a"))
        let index = StudioNoteLink.index([note])
        var audio = URLComponents(url: note.fileURL, resolvingAgainstBaseURL: false)!
        audio.fragment = "t=4.2-11.8"
        XCTAssertEqual(StudioNoteLink.resolve(try XCTUnwrap(audio.url), in: index)?.id, note.id)
        let meta = FileStore.metadataURL(forRecordingURL: note.fileURL)
        XCTAssertEqual(StudioNoteLink.resolve(meta, in: index)?.id, note.id)
    }

    func testSameBasenameElsewhereAndWebURLsNeverOpenTheWrongNote() throws {
        let first = entry(URL(fileURLWithPath: "/tmp/first/note.txt"))
        let second = entry(URL(fileURLWithPath: "/tmp/second/note.txt"))
        let index = StudioNoteLink.index([first, second])
        XCTAssertEqual(StudioNoteLink.resolve(first.fileURL, in: index)?.id, first.id)
        XCTAssertEqual(StudioNoteLink.resolve(second.fileURL, in: index)?.id, second.id)
        XCTAssertNil(StudioNoteLink.resolve(URL(fileURLWithPath: "/tmp/unrelated/note.txt"), in: index))
        XCTAssertNil(StudioNoteLink.resolve(try XCTUnwrap(URL(string: "https://example.com/note.txt")), in: index))
    }

    func testVoiceAndNoteCommentReferencesResolveLibraryPaths() throws {
        for prefix in ["voice:", "note:"] {
            let url = try XCTUnwrap(StudioNoteLink.referenceURL("\(prefix)Recordings/example.m4a.meta.json#t=4.2-11.8"))
            XCTAssertEqual(url, FileStore.resolveRelativePath("Recordings/example.m4a.meta.json").standardizedFileURL)
            XCTAssertNil(url.fragment)
        }
        XCTAssertNil(StudioNoteLink.referenceURL("https://example.com/note.txt"))
    }

    @MainActor
    func testHUDPresenterJoinsFullScreenSpacesWithKeyboardFocusAndReleasesClosedNote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "# Заметка\n\nТекст источника".write(to: file, atomically: true, encoding: .utf8)
        let note = entry(file), presenter = StudioNotePresenter()
        presenter.show(note, onSave: { _ in }, onOpenURL: { _ in false })
        let window = try XCTUnwrap(NSApp.windows.first(where: presenter.owns))
        defer { window.close() }
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(window.level, .floating)
        let panel = try XCTUnwrap(window as? NSPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        // Unlike the HUD, the note panel must accept a real text editor as first responder.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(window.firstResponder === editor)
        editor.removeFromSuperview()
        let controller = try XCTUnwrap(window.contentViewController)
        presenter.show(note, onSave: { _ in }, onOpenURL: { _ in false })
        XCTAssertTrue(window.contentViewController === controller, "Reopening the same note must preserve its form state")
        window.performClose(nil)
        XCTAssertNil(window.contentViewController)
    }
}
