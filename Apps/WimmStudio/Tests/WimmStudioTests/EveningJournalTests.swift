import AppKit
import SwiftUI
import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class EveningJournalTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testEveningRunsUntilFourAM() {
        XCTAssertEqual(EveningJournal.day(containing: date(2, 0, 40), calendar: calendar), date(1, 0))
        XCTAssertEqual(EveningJournal.day(containing: date(2, 3, 59), calendar: calendar), date(1, 0))
        XCTAssertEqual(EveningJournal.day(containing: date(2, 4, 0), calendar: calendar), date(2, 0))
        let interval = EveningJournal.interval(for: date(1, 0), calendar: calendar)
        XCTAssertEqual(interval.start, date(1, 4))
        XCTAssertEqual(interval.end, date(2, 4))
        XCTAssertEqual(EveningJournal.dateKey(date(1, 0), calendar: calendar), "2026-11-01")
    }

    func testPromptsRotateAndDiffer() {
        let today = EveningJournal.prompts(for: date(1, 0), calendar: calendar)
        let tomorrow = EveningJournal.prompts(for: date(2, 0), calendar: calendar)
        XCTAssertEqual(today.count, 2)
        XCTAssertNotEqual(today[0], today[1])
        XCTAssertNotEqual(today, tomorrow)
    }

    func testMarkdownRoundTripAndSectionOrder() {
        var document = EveningJournal.Document(title: "Вечер, 1 ноября", sections: [])
        document.setBody("мысль", of: EveningJournal.thoughtsHeading)
        document.setBody("ответ", of: "Что удивило?")
        document.setBody("- 16:35 — запись", of: EveningJournal.digestHeading)
        XCTAssertEqual(document.sections.map(\.heading), ["День", "Что удивило?", "Мысли"])
        let parsed = EveningJournal.Document(markdown: document.markdown)
        XCTAssertEqual(parsed, document)
        XCTAssertTrue(document.markdown.hasPrefix("# Вечер, 1 ноября\n\n## День\n\n- 16:35"))
    }

    func testSkippedQuestionsAreNotWritten() {
        var document = EveningJournal.Document(title: "t", sections: [])
        document.setBody("", of: EveningJournal.digestHeading)
        document.setBody("", of: "Что удивило?")
        document.setBody("", of: EveningJournal.thoughtsHeading)
        XCTAssertEqual(document.droppingEmptyQuestions().sections.map(\.heading), ["День", "Мысли"])
    }

    func testHandEditedMarkdownKeepsUnknownSections() {
        let markdown = "# Вечер\n\nвступление\n\n## День\n\n- a\n\n## Своё\n\nтекст\n\n## Мысли\n\nm\n"
        let document = EveningJournal.Document(markdown: markdown)
        XCTAssertEqual(document.sections.map(\.heading), ["", "День", "Своё", "Мысли"])
        XCTAssertEqual(EveningJournal.Document(markdown: document.markdown), document)
    }

    func testDigestGroupsNearbyPhotosAndLinksSidecars() {
        let notes = [
            EveningJournal.DayNote(date: date(1, 16, 35), title: "Пошёл дождь", kind: .voice,
                                   metadataName: "Wimm_A.meta.json", minutes: 3.6),
            EveningJournal.DayNote(date: date(1, 14, 32), title: "Фото", kind: .image,
                                   metadataName: "Wimm_P1.meta.json", minutes: 0.2),
            EveningJournal.DayNote(date: date(1, 14, 35), title: "Доска с планом", kind: .image,
                                   metadataName: "Wimm_P2.meta.json", minutes: 0.2),
            EveningJournal.DayNote(date: date(1, 18, 0), title: "Скриншот [1]", kind: .image,
                                   metadataName: "Wimm_P3.meta.json", minutes: 0.2),
        ]
        let lines = EveningJournal.digest(notes, calendar: calendar)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].text, "14:32 — [2 фото](Wimm_P1.meta.json) [·](Wimm_P2.meta.json): Доска с планом")
        XCTAssertEqual(lines[1].text, "16:35 — [Пошёл дождь · 4 мин](Wimm_A.meta.json)")
        XCTAssertEqual(lines[2].notes, ["Wimm_P3.meta.json"])
        let markdown = EveningJournal.digestMarkdown(lines)
        XCTAssertEqual(EveningJournal.linkedMetadataNames(in: markdown),
                       ["Wimm_A.meta.json", "Wimm_P1.meta.json", "Wimm_P2.meta.json", "Wimm_P3.meta.json"])
    }

    func testExifDateUsesOffsetWhenPresent() {
        let withOffset = EveningPhotos.exifDate("2026:11:01 14:32:10", offset: "+01:00")
        XCTAssertEqual(withOffset, ISO8601DateFormatter().date(from: "2026-11-01T13:32:10Z"))
        XCTAssertNotNil(EveningPhotos.exifDate("2026:11:01 14:32:10", offset: nil))
        XCTAssertNil(EveningPhotos.exifDate("garbage", offset: nil))
    }

    func testStoreCreatesFindsAndSaves() async throws {
        let day = EveningJournal.day(containing: Date())
        let created = try EveningJournalStore.create(day: day)
        defer {
            try? FileManager.default.removeItem(at: created.file)
            try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: created.file))
        }
        XCTAssertFalse(created.file.path.contains(NSHomeDirectory() + "/Library/Application Support/Wimm"),
                       "tests must never touch the real library")
        XCTAssertEqual(EveningJournalStore.find(day: day)?.file, created.file)

        var document = EveningJournal.Document(markdown: created.body)
        document.setBody("ответ", of: "Что удивило?")
        try await EveningJournalStore.save(body: document.markdown, previous: created.body, file: created.file,
                                           digest: (text: "- x", notes: []))
        let reloaded = EveningJournalStore.reload(created.file)
        XCTAssertEqual(reloaded.body, document.markdown)
        XCTAssertEqual(reloaded.generatedDigest, "- x")
    }

    /// One note = one media (2026-11-09): a spoken answer is its own audio
    /// note; the evening note holds the question and links to the answer.
    func testSpokenAnswerIsItsOwnNoteAndNoSidecarGetsAttachments() throws {
        let day = EveningJournal.day(containing: Date())
        let created = try EveningJournalStore.create(day: day)
        let audio = try EveningJournalStore.newAnswerAudioURL()
        try Data("aac".utf8).write(to: audio)
        defer {
            for url in [created.file, FileStore.metadataURL(forRecordingURL: created.file),
                        audio, FileStore.metadataURL(forRecordingURL: audio)] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        XCTAssertEqual(audio.deletingLastPathComponent(), FileStore.recordingsDirectory())
        XCTAssertTrue(audio.lastPathComponent.hasPrefix("Wimm_"))
        XCTAssertFalse(audio.lastPathComponent.contains("_Attach_"))

        try EveningJournalStore.recordAnswer(audio, text: " ответ ", prompt: "Что удивило?", day: day)

        let answerMeta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: audio))) as? [String: Any])
        XCTAssertNil(answerMeta["attachments"])
        XCTAssertNotNil(answerMeta[RecordingIdentity.metadataKey])
        let origin = try XCTUnwrap(answerMeta["origin"] as? [String: Any])
        XCTAssertEqual(origin["source"] as? String, EveningJournalStore.answerOriginSource)
        XCTAssertEqual(origin["journalPrompt"] as? String, "Что удивило?")
        let transcription = try XCTUnwrap(answerMeta["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["localTranscript"] as? String, "ответ")

        var document = EveningJournal.Document(markdown: created.body)
        let name = FileStore.metadataURL(forRecordingURL: audio).lastPathComponent
        document.setBody(EveningJournal.answerMarkdown(text: " ответ ", metadataName: name), of: "Что удивило?")
        XCTAssertEqual(document.body(of: "Что удивило?"), "ответ ([голос](\(name)))")
        XCTAssertEqual(EveningJournalStore.answerAudio(of: created.file, in: document).map(\.url), [audio])
        XCTAssertEqual(EveningJournalStore.answerAudio(of: created.file, in: document).map(\.prompt), ["Что удивило?"])
        XCTAssertEqual(EveningJournal.citedMetadataNames(in: document), [name])

        let eveningMeta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: created.file))) as? [String: Any])
        XCTAssertNil(eveningMeta["attachments"], "the evening note never lists answers as attachments")
    }

    func testLegacyAnswerAudioMovesOutOfTheNotesSession() throws {
        let day = EveningJournal.day(containing: Date())
        let created = try EveningJournalStore.create(day: day)
        let base = created.file.deletingPathExtension().lastPathComponent
        let legacy = created.file.deletingLastPathComponent().appendingPathComponent(base + "_Attach_20261101-195705_1.m4a")
        try Data("audio".utf8).write(to: legacy)
        defer {
            for url in [created.file, FileStore.metadataURL(forRecordingURL: created.file), legacy,
                        EveningJournalStore.answerDirectory(for: created.file)] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // A sidecar as written before 2026-11-09.
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: created.file)) { metadata in
            metadata["attachments"] = [["id": UUID().uuidString, "url": StoragePaths.relativePath(for: legacy),
                                        "type": "audio", "journalPrompt": "Мысли"]]
            return true
        }

        XCTAssertEqual(EveningJournalStore.relocateLegacyAnswerAudio(of: created.file), 1)
        let moved = try XCTUnwrap(EveningJournalStore.legacyAnswerAudio(of: created.file).first?.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(moved.lastPathComponent, "answer-20261101-195705_1.m4a")
        XCTAssertEqual(try Data(contentsOf: moved), Data("audio".utf8))
        XCTAssertEqual(EveningJournalStore.relocateLegacyAnswerAudio(of: created.file), 0)
        // Old answers still play until the split migration turns them into notes.
        XCTAssertEqual(EveningJournalStore.answerAudio(of: created.file, in: EveningJournal.Document(markdown: created.body))
            .map(\.prompt), ["Мысли"])
    }

    func testWizardWalkSkipsPhotosWhenThereAreNone() {
        XCTAssertEqual(EveningStep.walk(hasPhotos: false, promptCount: 2),
                       [.day, .prompt(0), .prompt(1), .thoughts, .done])
        XCTAssertEqual(EveningStep.walk(hasPhotos: true, promptCount: 2)[1], .photos)
    }

    func testWizardGreetingCountsInRussian() {
        func note(_ hour: Int, _ minute: Int) -> EveningJournal.DayNote {
            EveningJournal.DayNote(date: date(1, hour, minute), title: "x", kind: .voice, metadataName: "m", minutes: 1)
        }
        XCTAssertEqual(EveningWizardView.greeting([]), "Привет. Сегодня записей не было.")
        XCTAssertTrue(EveningWizardView.greeting([note(16, 6)]).hasPrefix("Привет. Сегодня у тебя одна запись, в "))
        XCTAssertTrue(EveningWizardView.greeting([note(16, 6), note(16, 41)]).contains("2 записи, с "))
        XCTAssertEqual(EveningWizardView.plural(5, "запись", "записи", "записей"), "записей")
        XCTAssertEqual(EveningWizardView.plural(21, "запись", "записи", "записей"), "запись")
        XCTAssertEqual(EveningWizardView.plural(12, "запись", "записи", "записей"), "записей")
    }

    @MainActor
    func testOpeningAndLeavingWritesNoNote() async {
        let model = EveningModel(day: date(1, 0))
        await model.saveNow()
        XCTAssertNil(model.file, "an untouched evening must leave nothing behind")
    }

    /// Renders the conversation's steps over a fake day; `WIMM_SNAPSHOT_DIR` keeps the PNGs.
    @MainActor
    func testEveningWizardRenders() async throws {
        let day = EveningJournal.day(containing: Date())
        let start = Calendar.current.startOfDay(for: day)
        let directory = FileStore.recordingsDirectory()
        let titles = [(16, 6, "Сидим с Алиной в кафе, обсуждаем выходные"), (16, 12, "Идея: вечерний журнал как разговор"),
                      (16, 20, "Wimm Studio: HUD-остров по наведению"), (16, 33, "Тяжёлый разговор"),
                      (16, 41, "Надо проверить синхронизацию с телефоном, а потом")]
        let notes = titles.map { hour, minute, title in
            let date = Calendar.current.date(byAdding: .minute, value: hour * 60 + minute, to: start)!
            return StudioLibraryNote(Note(id: UUID(), index: 0,
                                          fileURL: directory.appendingPathComponent("Wimm_test_\(hour)\(minute).m4a"),
                                          fileCreated: date, start: 0, end: 0, text: title, isFailed: false,
                                          hasRaw: false, title: title))
        }
        let model = EveningModel(day: day)
        model.update(notes: notes)
        XCTAssertEqual(model.dayNotes.count, 5)
        defer {
            if let file = model.file {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: file))
            }
        }

        func render(_ step: EveningStep, _ name: String) async throws {
            let view = EveningWizardView(model: model, recentNotes: RecentNotes(), capture: CaptureSession(),
                                         recorder: EveningVoiceRecorder(), photos: EveningPhotos(),
                                         onOpenNote: { _ in }, onFilesAdded: { _ in }, onWholeNote: {}, onClose: {},
                                         initialStep: step)
            let hosting = NSHostingView(rootView: view)
            hosting.appearance = NSAppearance(named: .aqua)
            hosting.frame = NSRect(x: 0, y: 0, width: 860, height: 640)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.orderOut(nil) }
            window.contentView = hosting
            window.orderFrontRegardless()
            for _ in 0..<6 { try await Task.sleep(nanoseconds: 100_000_000) }
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 15_000, "evening wizard step \(name) rendered blank")
            if let dir = ProcessInfo.processInfo.environment["WIMM_SNAPSHOT_DIR"] {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("studio-evening-\(name).png"))
            }
        }

        try await render(.day, "1-day")
        model.setBody("Разговор с Алиной. Кажется, мы наконец услышали друг друга.", of: model.prompts[0])
        try await render(.prompt(0), "3-question")
        try await render(.thoughts, "5-thoughts")
        await model.closeDay()
        XCTAssertNotNil(model.closedAt)
        try await render(.done, "6-done")
    }
}
