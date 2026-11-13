import XCTest
import AppKit
import AVFoundation
import CoreGraphics
import SwiftUI
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class StudioNotePreviewTests: XCTestCase {
    private func note(_ url: URL, text: String = "Текст", refined: String? = nil,
                      attachments: [NoteAttachment] = []) -> Note {
        Note(id: UUID(), index: 0, fileURL: url, fileCreated: Date(), start: 0, end: 0,
             text: text, refinedText: refined, isFailed: false, hasRaw: false, attachments: attachments)
    }

    func testTextHasNoEmptySourceOrHistoryTabs() {
        let content = StudioNoteContent(note: note(URL(fileURLWithPath: "/tmp/plain.txt")), metadata: [:], versions: [])
        XCTAssertEqual(content.tabs.map(\.id), ["body"])
        XCTAssertEqual(content.initialTabID, "body")
    }

    func testImagesDocumentsAndScansOpenTheirOriginalWithSeparateExtraction() {
        for ext in ["png", "heic", "tiff", "bmp", "webp", "pdf", "docx"] {
            let file = URL(fileURLWithPath: "/tmp/source.\(ext)")
            let content = StudioNoteContent(note: note(file), metadata: [
                "ocr": ["text": "Оригинальные строки\nсо скана"],
            ], versions: [])
            XCTAssertEqual(content.initialTabID, "source:\(file.path)")
            guard case .source(let url) = content.tabs.first(where: { $0.id == content.initialTabID })?.content else {
                return XCTFail("Original must be directly accessible")
            }
            XCTAssertEqual(url, file)
            guard case .text(let text, _) = content.tabs.first(where: { $0.id == "ocr" })?.content else {
                return XCTFail("OCR must be separate from the editable note body")
            }
            XCTAssertEqual(text, "Оригинальные строки\nсо скана")
        }
    }

    func testAllTranscriptKindsAndOlderEvidenceRemainAccessible() {
        let file = URL(fileURLWithPath: "/tmp/voice.m4a")
        let metadata: [String: Any] = ["transcription": [
            "transcript": "Текущий облачный текст", "provider": "gemini", "model": "gemini-flash-latest",
            "localTranscript": "Текст во время записи",
            "previousRuns": [
                ["transcript": "Локальный текст", "provider": "parakeet", "model": "parakeet:ultra"],
                ["transcript": "Более старый облачный текст", "provider": "gemini", "model": "gemini-old"],
            ],
        ]]
        let content = StudioNoteContent(note: note(file), metadata: metadata, versions: [])
        let texts = content.tabs.compactMap { tab -> String? in
            if case .text(let text, _) = tab.content { return text }; return nil
        }
        XCTAssertEqual(Set(texts), ["Текущий облачный текст", "Текст во время записи", "Локальный текст", "Более старый облачный текст"])
        XCTAssertEqual(content.audioURL, file)
        XCTAssertEqual(content.initialTabID, "body")
    }

    func testAttachmentOriginalAndOCRSurviveAlongsideParentText() {
        let image = URL(fileURLWithPath: "/tmp/photo.png")
        let attachment = NoteAttachment(url: image, type: .image, extractedText: "Текст фотографии")
        let content = StudioNoteContent(note: note(URL(fileURLWithPath: "/tmp/import.txt"), attachments: [attachment]),
                                        metadata: [:], versions: [])
        XCTAssertTrue(content.tabs.contains { if case .source(image) = $0.content { return true }; return false })
        XCTAssertTrue(content.tabs.contains { if case .text("Текст фотографии", _) = $0.content { return true }; return false })
        XCTAssertEqual(content.bodyText, "Текст")
    }

    func testLegacyOCROnlyDeduplicatesExactCopiesOfTheSameSource() {
        let file = URL(fileURLWithPath: "/tmp/photo.png")
        let attachment = NoteAttachment(url: file, type: .image, extractedText: "Текст фотографии")
        let metadata: [String: Any] = [
            "ocr": ["text": "Текст фотографии", "provider": "vision"],
            "transcription": ["transcript": "Текст фотографии", "provider": "vision",
                              "previousRuns": [["transcript": "Более раннее чтение", "provider": "vision"]]],
        ]
        let content = StudioNoteContent(note: note(file, attachments: [attachment]), metadata: metadata, versions: [])
        let texts = content.tabs.compactMap { tab -> String? in
            if case .text(let text, _) = tab.content { return text }; return nil
        }
        XCTAssertEqual(texts.filter { $0 == "Текст фотографии" }.count, 1)
        XCTAssertTrue(texts.contains("Более раннее чтение"))
        XCTAssertEqual(content.tabs.first?.id, content.initialTabID)
    }

    func testSaveMergesOnlyEditedFieldsAndKeepsUndoableHistory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("note.txt")
        try "Исходный текст".write(to: file, atomically: true, encoding: .utf8)
        let sidecar = FileStore.metadataURL(forRecordingURL: file)
        try FileStore.mutateSidecar(at: sidecar) { meta in
            meta = ["syncId": "keep-sync", "transcription": ["transcript": "keep-transcript"],
                    "noteCard": ["schema": Schemas.noteCard, "note_file": file.lastPathComponent,
                                 "title": "Заголовок", "summary": "Сводка", "is_liked": true,
                                 "is_draft": true, "provider": "keep-provider", "futureField": 42,
                                 "refined_text": "До правки"]]
            return true
        }
        let content = StudioNoteContent(note: note(file, text: "Исходный текст", refined: "До правки"), metadata: [:], versions: [])
        let history = NoteVersionStore(directory: dir.appendingPathComponent("history"))
        let versions = try await StudioNoteWriter.save("## После правки\n\nНовая мысль.", content: content, history: history)
        let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        let card = try XCTUnwrap(meta["noteCard"] as? [String: Any])
        XCTAssertEqual(meta["syncId"] as? String, "keep-sync")
        XCTAssertEqual((meta["transcription"] as? [String: Any])?["transcript"] as? String, "keep-transcript")
        XCTAssertEqual(card["is_liked"] as? Bool, true)
        XCTAssertEqual(card["is_draft"] as? Bool, true)
        XCTAssertEqual(card["futureField"] as? Int, 42)
        XCTAssertEqual(card["provider"] as? String, "keep-provider")
        XCTAssertNotNil(card["refined_edited_at"] as? Double)
        XCTAssertEqual(versions.first?.text, "До правки")
        XCTAssertEqual(versions.last?.text, "## После правки\n\nНовая мысль.")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Исходный текст")

        do {
            _ = try await StudioNoteWriter.save("Устаревшая правка", content: content, history: history)
            XCTFail("A stale editor must not replace a newer body")
        } catch StudioNoteEditError.changedElsewhere { }
    }

    /// Opt-in native renders: no real library and no model calls. They also exercise the
    /// asynchronous note/source load rather than drawing a second implementation of the UI.
    @MainActor
    func testNativePreviewFixtures() async throws {
        guard let output = ProcessInfo.processInfo.environment["WIMM_STUDIO_PREVIEW_SNAPSHOTS"] else {
            throw XCTSkip("Set WIMM_STUDIO_PREVIEW_SNAPSHOTS to inspect native note previews")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let markdown = """
        ## Возвращаться к мысли

        Хочу открывать документ и **сразу возвращаться к своей мысли**. Если формулировка неточна — свериться с оригиналом.

        - Спокойное чтение и понятные абзацы.
        - Доступ к оригиналу в один шаг.

        > Сначала прочитать, потом уточнить.

        | Источник | Действие |
        | --- | --- |
        | Запись | Послушать |
        | Скан | Посмотреть страницу |
        """
        let text = dir.appendingPathComponent("text.txt")
        try markdown.write(to: text, atomically: true, encoding: .utf8)

        let image = dir.appendingPathComponent("image.png")
        let drawing = NSImage(size: NSSize(width: 900, height: 520))
        drawing.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 900, height: 520).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.darkGray]
        ("Мысль → Запись → Документ" as NSString).draw(at: NSPoint(x: 95, y: 300), withAttributes: attributes)
        ("Вернуться к источнику и уточнить" as NSString).draw(at: NSPoint(x: 95, y: 180), withAttributes: attributes)
        drawing.unlockFocus()
        let bitmap = try XCTUnwrap(drawing.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: image)

        let pdf = dir.appendingPathComponent("document.pdf")
        var rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &rect, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.draw(try XCTUnwrap(bitmap.cgImage), in: CGRect(x: 30, y: 360, width: 535, height: 310))
            context.endPDFPage()
        }
        context.closePDF()
        let scan = dir.appendingPathComponent("scan.pdf")
        try FileManager.default.copyItem(at: pdf, to: scan)
        let audio = dir.appendingPathComponent("voice.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        memset(try XCTUnwrap(buffer.floatChannelData)[0], 0, 16_000 * MemoryLayout<Float>.size)
        do { let file = try AVAudioFile(forWriting: audio, settings: format.settings); try file.write(from: buffer) }
        let fixtures = [("text", text), ("image", image), ("document", pdf), ("scan", scan), ("audio", audio)]
        for (name, file) in fixtures {
            try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: file)) { meta in
                meta["noteCard"] = ["schema": Schemas.noteCard, "note_file": file.lastPathComponent,
                                    "title": "Как я хочу работать со Studio", "summary": "", "refined_text": markdown]
                if name == "audio" {
                    meta["transcription"] = ["transcript": "Сохранённая расшифровка", "provider": "parakeet",
                                             "model": "parakeet:ultra", "audioDurationSec": 1,
                                             "localTranscript": "Текст во время записи"]
                } else if name != "text" { meta["ocr"] = ["text": "Мысль → Запись → Документ", "provider": "vision"] }
                return true
            }
            let loaded = await NoteBuilder.build(file: file, index: 0, metaRepo: MetadataRepository(),
                                                transcriptRepo: TranscriptRepository(), includeSearchMetadata: false)
            let host = NSHostingView(rootView: StudioNotePreview(entry: StudioLibraryNote(loaded), onSelectBlock: {})
                .environment(\.colorScheme, .light))
            let size = NSSize(width: name == "text" ? 540 : 700, height: 760)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.backgroundColor = .windowBackgroundColor
            window.contentView = host; window.setContentSize(size); window.orderFrontRegardless()
            for _ in 0..<15 { try await Task.sleep(for: .milliseconds(100)) }
            host.layoutSubtreeIfNeeded()
            let rendered = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rendered)
            let png = try XCTUnwrap(rendered.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000, "\(name) rendered blank")
            try png.write(to: outputURL.appendingPathComponent("studio-note-\(name).png"))
            window.close()
        }
    }
}
