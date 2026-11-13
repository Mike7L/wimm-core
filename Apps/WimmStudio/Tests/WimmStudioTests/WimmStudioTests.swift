import XCTest
import SwiftUI
import AppKit
import WimmDocumentUI
@testable import WimmStudio
import WimmDomain
import WimmInfrastructure

final class WimmStudioTests: XCTestCase {
    @MainActor
    func testDocumentUsesWimmTypographyAndSecretaryAsides() throws {
        let rendered = BlockRenderer.render("A paragraph. ^[A doubt [S205].]", baseURL: nil, style: .init())
        XCTAssertFalse(rendered.string.contains("^["))
        let font = try XCTUnwrap(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 14)
        let aside = (rendered.string as NSString).range(of: "A doubt").location
        XCTAssertNotNil(rendered.attribute(PersonalDocumentRendering.asideKey, at: aside, effectiveRange: nil))
        let wrapped = BlockRenderer.render("A soft\nline break.", baseURL: nil, style: .init())
        XCTAssertEqual(wrapped.string, "A soft line break.")
    }

    /// The secretary window renders its settings, queue and history (a blank render once hid all text).
    @MainActor
    func testSecretaryWindowRenders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-secretary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["docs", "secretary/runs"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let document = root.appendingPathComponent("docs/me.md")
        try "# Документ\n".write(to: document, atomically: true, encoding: .utf8)
        let model = DocumentModel(url: document)
        let view = SecretaryWindowView(secretary: model.secretary, actions: SecretaryWindowActions(
            document: { document }, pendingThreads: { 0 }, canStart: { true }, answerComments: {}, runPass: {}))
        let size = CGSize(width: 1000, height: 740)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        window.contentView = hosting
        window.orderFrontRegardless()
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 100_000_000) }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 20_000, "secretary window rendered blank")
        if let dir = ProcessInfo.processInfo.environment["WIMM_SNAPSHOT_DIR"] {
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("studio-secretary-window.png"))
        }
    }

    @MainActor
    func testSecretaryDoesNotStartOverAnOpenDraft() async throws {
        let model = DocumentModel(url: URL(fileURLWithPath: "/tmp/draft-document.md"))
        model.isEditing = true
        model.runSecretary(.pass)
        XCTAssertFalse(model.secretary.isRunning)
    }

    func testTextUnitsSentenceAndWordSelection() throws {
        let text = "Первое предложение. Второе длинное предложение!\n• Пункт списка без точки\nСледующая строка."
        let ns = text as NSString

        // Click inside the second sentence ("длинное"):
        let idxSecond = ns.range(of: "длинное").location + 2
        let sentenceRange = try XCTUnwrap(TextUnits.sentence(at: idxSecond, in: text))
        XCTAssertEqual(ns.substring(with: sentenceRange), "Второе длинное предложение!")

        // Double-click on "длинное" selects just the word:
        let wordRange = try XCTUnwrap(TextUnits.word(at: idxSecond, in: text))
        XCTAssertEqual(ns.substring(with: wordRange), "длинное")

        // Click inside a bullet line without a period stays within that line:
        let idxBullet = ns.range(of: "списка").location
        let bulletSentence = try XCTUnwrap(TextUnits.sentence(at: idxBullet, in: text))
        XCTAssertEqual(ns.substring(with: bulletSentence), "• Пункт списка без точки")
    }

    func testTimelineUses700CharsPerMinuteAnd10SecondsForTextlessImage() {
        let now = Date()
        let textNote = Note(
            id: UUID(), index: 0,
            fileURL: URL(fileURLWithPath: "/tmp/note.txt"),
            fileCreated: now, start: 0, end: 0,
            text: String(repeating: "а", count: 1_400),
            isFailed: false, hasRaw: false
        )
        XCTAssertEqual(StudioTimeline.minutes(of: textNote), 2.0, accuracy: 0.0001)

        let textlessImage = Note(
            id: UUID(), index: 1,
            fileURL: URL(fileURLWithPath: "/tmp/photo.heic"),
            fileCreated: now, start: 0, end: 0,
            text: "",
            isFailed: false, hasRaw: false
        )
        XCTAssertEqual(StudioTimeline.minutes(of: textlessImage), 10.0 / 60.0, accuracy: 0.0001)

        let ocrImage = Note(
            id: UUID(), index: 2,
            fileURL: URL(fileURLWithPath: "/tmp/scan.png"),
            fileCreated: now, start: 0, end: 0,
            text: String(repeating: "б", count: 700),
            isFailed: false, hasRaw: false
        )
        XCTAssertEqual(StudioTimeline.minutes(of: ocrImage), 1.0, accuracy: 0.0001)
    }

    func testResponsiveHUDLayoutAcrossContinuousSizes() {
        // Nano pill size (78 x 32):
        let pill = ResponsiveHUDLayout(width: 78, height: 32)
        XCTAssertEqual(pill.listHeight, 0)
        XCTAssertEqual(pill.controlBarHeight, 32)
        XCTAssertFalse(pill.showsTimer)
        XCTAssertFalse(pill.showsSend)
        XCTAssertFalse(pill.showsStatusText)
        XCTAssertFalse(pill.showsLeadingActions)

        // Compact bar size (360 x 38): actions, Send, no captions, no status text.
        let bar = ResponsiveHUDLayout(width: 360, height: 38)
        XCTAssertEqual(bar.listHeight, 0)
        XCTAssertEqual(bar.controlBarHeight, 38)
        XCTAssertTrue(bar.showsTimer)
        XCTAssertTrue(bar.showsSend)
        XCTAssertTrue(bar.showsLeadingActions)
        XCTAssertFalse(bar.showsCaptions)
        XCTAssertFalse(bar.showsStatusText)

        // Narrow bar keeps leading actions without captions.
        let narrow = ResponsiveHUDLayout(width: 280, height: 38)
        XCTAssertTrue(narrow.showsLeadingActions)
        XCTAssertFalse(narrow.showsCaptions)

        // Expanded HUD size (360 x 240):
        let full = ResponsiveHUDLayout(width: 360, height: 240)
        XCTAssertEqual(full.listHeight, 202)
        XCTAssertEqual(full.listOpacity, 1.0, accuracy: 0.001)
        XCTAssertTrue(full.showsLeadingActions)
    }

    func testCustomReactionAndVoiceViaRoundTripInDocumentComments() throws {
        let loc = DocumentCommentLocation(fileURL: URL(fileURLWithPath: "/tmp/threads.jsonl"), doc: "docs/me_structured.md")
        let target = CommentTarget(
            documentURL: URL(fileURLWithPath: "/tmp/me_structured.md"),
            section: "work",
            heading: "Работа",
            selector: TextQuoteSelector(quote: "люблю горы", prefix: "Я ", suffix: " и море")
        )

        let customReaction = CommentRecords.root(in: loc, target: target, text: nil, reaction: "🔥")
        XCTAssertEqual(customReaction.kind, .reaction)
        XCTAssertEqual(customReaction.reaction, "🔥")
        XCTAssertEqual(customReaction.intent, "custom")

        let voiceComment = CommentRecords.root(
            in: loc,
            target: target,
            text: "Уточнить про Кавказ",
            reaction: nil,
            via: "voice:Recordings/Wimm_2026-10-25_17-30-00_ABCD1234.m4a.meta.json#t=4.2-11.8"
        )
        let data = try JSONEncoder().encode(voiceComment)
        let decoded = try JSONDecoder().decode(DocumentCommentRecord.self, from: data)
        XCTAssertEqual(decoded.via, "voice:Recordings/Wimm_2026-10-25_17-30-00_ABCD1234.m4a.meta.json#t=4.2-11.8")
        XCTAssertEqual(decoded.quote, "люблю горы")
    }

    @MainActor
    func testDocumentModelAndResponsiveHUDPanelResizeWithoutIdentityLoss() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let docURL = dir.appendingPathComponent("me_structured.md")
        try "# Обо мне\n\n## Привычки\n\nПервое предложение о чае. Второе предложение о горах.\n"
            .write(to: docURL, atomically: true, encoding: .utf8)

        let model = DocumentModel(url: docURL)
        await model.load()
        let document = try XCTUnwrap(model.document)
        let bodyBlock = try XCTUnwrap(document.blocks.last)
        let selector = TextQuoteSelector(quote: "Первое предложение о чае.", prefix: "", suffix: " Второе")
        let target = try XCTUnwrap(model.target(for: bodyBlock, selector: selector))

        await model.add(target, text: nil, reaction: "🔥")
        XCTAssertEqual(model.threads.count, 1)
        XCTAssertEqual(model.threads.first?.root.reaction, "🔥")
        XCTAssertEqual(model.threads.first?.root.intent, "custom")

        let created = await model.createNote(
            after: bodyBlock,
            text: "Новая заметка после абзаца",
            plainBlockText: "Первое предложение о чае. Второе предложение о горах."
        )
        let noteURL = try XCTUnwrap(created)
        XCTAssertTrue(FileManager.default.fileExists(atPath: noteURL.path))
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "Новая заметка после абзаца")
        XCTAssertEqual(model.threads.count, 2)
        XCTAssertTrue(model.threads.last?.root.via?.hasPrefix("note:Recordings/") == true)

        // Verify ResponsiveHUDPanel can smoothly resize across pill -> bar -> full without crashing:
        let capture = CaptureSession()
        let recent = RecentNotes(limit: 5)
        let panel = ResponsiveHUDPanel(
            rootView: ResponsiveHUDView(capture: capture, recentNotes: recent, onOpenDocument: {})
        )
        defer { panel.close() }
        XCTAssertFalse(panel.styleMask.contains(.resizable))
        let subview = NSButton(frame: .zero)
        panel.contentView?.addSubview(subview)
        _ = panel.makeFirstResponder(subview)
        XCTAssertFalse(panel.firstResponder === subview)

        for size in [NSSize(width: 78, height: 32), NSSize(width: 360, height: 38), NSSize(width: 360, height: 240)] {
            panel.setFrame(NSRect(origin: CGPoint(x: 100, y: 100), size: size), display: true)
            XCTAssertEqual(panel.frame.size, size)
            // Both right corners and the top edge are active resize targets:
            XCTAssertTrue(panel.isInResizeCorner(at: NSPoint(x: size.width - 2, y: 2)))
            XCTAssertFalse(panel.isInResizeCorner(at: NSPoint(x: 2, y: 2)))
            XCTAssertTrue(panel.isInResizeCorner(at: NSPoint(x: size.width - 2, y: size.height - 2)))
            XCTAssertTrue(panel.isInResizeCorner(at: NSPoint(x: 2, y: size.height - 2)))
            XCTAssertFalse(panel.isInResizeCorner(at: NSPoint(x: size.width / 2, y: 2)))
            XCTAssertEqual(panel.isInResizeCorner(at: NSPoint(x: size.width - 2, y: size.height / 2)), size.height <= 36)
        }
    }

    @MainActor
    func testSaveConfirmationHasVisibleSizeWithoutTakingFocus() async throws {
        let receipt = StudioSaveConfirmation()
        receipt.show(count: 1)
        defer { receipt.dismiss() }
        let window = try XCTUnwrap(NSApp.windows.first {
            $0.identifier?.rawValue == "studio.saveConfirmation" && $0.isVisible
        })
        let panel = try XCTUnwrap(window as? NSPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertGreaterThan(panel.frame.width, 100)
        XCTAssertGreaterThan(panel.frame.height, 30)
        XCTAssertFalse(panel.isKeyWindow)
        receipt.show(count: 3, duration: .milliseconds(40))
        XCTAssertGreaterThan(panel.frame.width, 150)
        XCTAssertTrue(panel.isVisible)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testHUDResizesUpFromBottomOfScreenAndClampsToVisibleBounds() {
        let bounds = NSRect(x: 100, y: 40, width: 1000, height: 800)
        let start = NSRect(x: 200, y: 40, width: 360, height: 38)
        let taller = ResponsiveHUDPanel.resizedFrame(start, delta: NSPoint(x: 50, y: 200),
                                                   handle: .top, bounds: bounds)
        XCTAssertEqual(taller, NSRect(x: 200, y: 40, width: 360, height: 238))
        let largest = ResponsiveHUDPanel.resizedFrame(start, delta: NSPoint(x: 2000, y: 2000),
                                                    handle: .topRight, bounds: bounds)
        XCTAssertEqual(largest.minY, bounds.minY)
        XCTAssertEqual(largest.maxY, bounds.maxY)
        XCTAssertEqual(largest.maxX, bounds.maxX)
        let bottom = ResponsiveHUDPanel.resizedFrame(start, delta: NSPoint(x: 0, y: -200),
                                                   handle: .bottomRight, bounds: bounds)
        XCTAssertEqual(bottom, start)
    }

    func testNoteAnalysisConfigurationIsDisabledByDefaultAndToggleable() {
        let originalShared = SharedUserDefaults.store.object(forKey: DefaultsKey.processingNoteCardEnabled)
        let originalStandard = UserDefaults.standard.object(forKey: DefaultsKey.processingNoteCardEnabled)
        defer {
            if let originalShared {
                SharedUserDefaults.store.set(originalShared, forKey: DefaultsKey.processingNoteCardEnabled)
            } else {
                SharedUserDefaults.store.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
            }
            if let originalStandard {
                UserDefaults.standard.set(originalStandard, forKey: DefaultsKey.processingNoteCardEnabled)
            } else {
                UserDefaults.standard.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
            }
        }

        SharedUserDefaults.store.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)

        XCTAssertFalse(ProcessingCfg.noteCardEnabled, "Analysis must be disabled by default in Studio")
        XCTAssertFalse(ProcessingCfg.analysisEnabled)

        ProcessingCfg.noteCardEnabled = true
        XCTAssertTrue(ProcessingCfg.noteCardEnabled)
        XCTAssertTrue(ProcessingCfg.analysisEnabled)

        ProcessingCfg.noteCardEnabled = false
        XCTAssertFalse(ProcessingCfg.noteCardEnabled)
    }

    func testHUDIslandGeometryAttachesToNearestEdgeAndKeepsAnchor() {
        let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let near = NSRect(x: 400, y: 772, width: 56, height: 18)
        XCTAssertEqual(HUDIslandGeometry.nearestEdge(of: near, in: bounds), .top)
        XCTAssertEqual(HUDIslandGeometry.nearestEdge(of: NSRect(x: 3, y: 300, width: 18, height: 56), in: bounds), .left)
        XCTAssertEqual(HUDIslandGeometry.nearestEdge(of: NSRect(x: 960, y: 300, width: 18, height: 56), in: bounds), .right)
        XCTAssertEqual(HUDIslandGeometry.nearestEdge(of: NSRect(x: 400, y: 5, width: 56, height: 18), in: bounds), .bottom)

        let along = HUDIslandGeometry.along(of: near, edge: .top, in: bounds)
        let pill = HUDIslandGeometry.collapsedFrame(edge: .top, along: along, in: bounds)
        XCTAssertEqual(pill.maxY, bounds.maxY)
        XCTAssertEqual(pill.midX, near.midX, accuracy: 0.5)
        XCTAssertEqual(pill.size, NSSize(width: 56, height: 18))

        // Expanding keeps the edge and the anchor; it never leaves the screen.
        let open = HUDIslandGeometry.frame(edge: .top, along: along, size: NSSize(width: 360, height: 220), in: bounds)
        XCTAssertEqual(open.maxY, bounds.maxY)
        XCTAssertEqual(open.midX, pill.midX, accuracy: 0.5)
        let cornerOpen = HUDIslandGeometry.frame(edge: .right, along: 1, size: NSSize(width: 360, height: 220), in: bounds)
        XCTAssertEqual(cornerOpen.maxX, bounds.maxX)
        XCTAssertTrue(bounds.contains(cornerOpen))
        XCTAssertEqual(HUDIslandGeometry.collapsedSize(for: .left), NSSize(width: 18, height: 56))
    }

    @MainActor
    func testHUDIslandPanelCollapsesToEdgeAndExpandsOnClick() {
        let defaults = UserDefaults.standard
        let keys = ["WimmStudio.hudIsland", "WimmStudio.hudIslandEdge", "WimmStudio.hudIslandAlong", "WimmStudio.hudIslandExpandedSize"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { defaults.set(v, forKey: k) } else { defaults.removeObject(forKey: k) } } }
        keys.forEach { defaults.removeObject(forKey: $0) }

        let island = HUDIslandModel()
        let hudView = ResponsiveHUDView(capture: CaptureSession(), recentNotes: RecentNotes(limit: 5), onOpenDocument: {}, island: island)
        let panel = ResponsiveHUDPanel(
            rootView: hudView,
            island: island
        )
        defer { panel.close() }
        XCTAssertEqual(ResponsiveHUDPanel.hoverExpandDelay, 0.7, accuracy: 0.01)
        XCTAssertNotNil(island.onTapPill)
        let bounds = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: bounds.midX - 180, y: bounds.maxY - 230, width: 360, height: 220), display: true)

        panel.setIslandEnabled(true, animated: false)
        XCTAssertEqual(island.edge, .top)
        XCTAssertTrue(hudView.placesControlBarAtTop)
        XCTAssertFalse(island.isExpanded)
        XCTAssertTrue(island.showsPill)
        XCTAssertEqual(panel.frame.size, NSSize(width: 56, height: 18))
        XCTAssertEqual(panel.frame.maxY, bounds.maxY, accuracy: 0.5)
        let anchor = panel.frame.midX

        panel.toggleIsland(animated: false)
        XCTAssertTrue(island.isExpanded)
        XCTAssertEqual(panel.frame.size, NSSize(width: 360, height: 220))
        XCTAssertEqual(panel.frame.maxY, bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(panel.frame.midX, anchor, accuracy: 0.5)
        // Top edge is attached to the screen and hosts the record switch, not a resize handle.
        XCTAssertFalse(panel.isInResizeCorner(at: NSPoint(x: 180, y: 218)))
        XCTAssertTrue(panel.isInResizeCorner(at: NSPoint(x: 355, y: 5)))

        panel.toggleIsland(animated: false)
        XCTAssertFalse(island.isExpanded)
        XCTAssertLessThan(panel.alphaValue, 1)

        // Hover opens the island, leaving closes it again.
        panel.islandPointerEntered()
        XCTAssertTrue(island.isExpanded)
        XCTAssertEqual(panel.alphaValue, 1)
        panel.islandPointerExited()
        XCTAssertFalse(island.isExpanded)
        XCTAssertEqual(panel.frame.size, NSSize(width: 56, height: 18))

        panel.setIslandEdge(.left, animated: false)
        XCTAssertFalse(hudView.placesControlBarAtTop)
        XCTAssertEqual(panel.frame.size, NSSize(width: 18, height: 56))
        XCTAssertEqual(panel.frame.minX, bounds.minX, accuracy: 0.5)
        XCTAssertFalse(panel.isInResizeCorner(at: NSPoint(x: 28, y: 2)))
    }
}
