import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class VikContextToolsTests: XCTestCase {
    private let document = "# Документ\n\n## Семья\n\nЖивут в Киле.\n\n## Работа\n\nДругая тема."
    private var current: URL { StoragePaths.baseDirectory().appendingPathComponent("Wimm_2026-11-06_19-00-00_CURRENT.aac") }

    func testReadsSecretaryOutlineSectionAndExactBlocksWithoutChangingDocument() async throws {
        let tools = VikContextTools(document: document, source: current, isAllowed: { true }, files: { [] })
        let outline = try object(await tools.read("document_outline", arguments: "{}"))
        let items = try XCTUnwrap(outline["items"] as? [[String: Any]])
        let family = try XCTUnwrap(items.first { ($0["title"] as? String) == "## Семья" }?["id"] as? String)
        let section = try object(await tools.read("document_section", arguments: "{\"id\":\"\(family)\"}"))
        XCTAssertEqual(section["status"] as? String, "complete")
        let blocks = try XCTUnwrap(section["blocks"] as? [[String: Any]])
        let body = try XCTUnwrap(blocks.first { ($0["text"] as? String)?.contains("Киле") == true }?["id"] as? String)
        let read = try await tools.read("document_blocks", arguments: "{\"ids\":[\"\(body)\",\"b999999\"]}")
        XCTAssertTrue(read.contains("Киле")); XCTAssertFalse(read.contains("Другая тема"))
        XCTAssertEqual(try object(read)["missing"] as? [String], ["b999999"])
        let transcript = await tools.transcript()
        XCTAssertTrue(transcript.contains("document_section")); XCTAssertTrue(transcript.contains("Киле"))
    }

    func testPreviousAndHourExcludeCurrentAndFutureAndReadLegacyLiveEvidence() async throws {
        let dir = StoragePaths.baseDirectory().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["Wimm_2026-11-06_17-00-00_OLD.txt", "Wimm_2026-11-06_18-30-00_PRIOR.aac",
                     "Wimm_2026-11-06_19-00-00_CURRENT.aac", "Wimm_2026-11-06_19-01-00_FUTURE.txt"]
        let files = names.map { dir.appendingPathComponent($0) }
        try Data("Старое".utf8).write(to: files[0])
        try Data().write(to: files[1])
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: files[1])) { meta in
            meta["transcription"] = ["localTranscript": "Они живут в Киле", "transcript": "Они живут у моря", "provider": "parakeet"]
            return true
        }
        let now = try XCTUnwrap(FileStore.recordingDateFromFileName(files[2])).addingTimeInterval(12)
        let tools = VikContextTools(document: "", source: files[2], asOf: now, isAllowed: { true }, files: { files })
        let list = try object(await tools.read("notes_last_hour", arguments: "{}"))
        XCTAssertEqual(list["total"] as? Int, 1)
        let previous = try await tools.read("previous_note", arguments: "{}")
        XCTAssertTrue(previous.contains("Киле")); XCTAssertTrue(previous.contains("у моря"))
        XCTAssertFalse(previous.contains("Старое"))
        let id = try XCTUnwrap(try object(previous)["id"] as? String)
        let exact = try await tools.read("read_note", arguments: "{\"id\":\"\(id)\"}")
        XCTAssertEqual(try object(exact)["text"] as? String, try object(previous)["text"] as? String)
        let missing = try await tools.read("read_note", arguments: "{\"id\":\"../secret\"}")
        XCTAssertTrue(missing.hasPrefix("not_found"))
    }

    func testRevokedReadReturnsNoEvidenceEvenWhenLoaderFinishesLate() async throws {
        let gate = ReadGate()
        let source = current
        let tools = VikContextTools(document: document, source: source, isAllowed: { await gate.allowed },
                                    files: { [source.deletingLastPathComponent().appendingPathComponent("Wimm_2026-11-06_18-59-00_PREV.txt")] },
                                    load: { _ in await gate.load() })
        let task = Task { try await tools.read("previous_note", arguments: "{}") }
        for _ in 0..<200 { if await gate.loading { break }; try await Task.sleep(for: .milliseconds(2)) }
        await gate.revoke()
        do { _ = try await task.value; XCTFail("revoked read must fail") } catch is CancellationError {} 
        let transcript = await tools.transcript()
        XCTAssertTrue(transcript.isEmpty)
    }

    func testPreloadedCarriesOutlineAndHourListAndIsKeptAsEvidence() async throws {
        let tools = VikContextTools(document: document, source: current, isAllowed: { true }, files: { [] })
        let context = try await tools.preloaded()
        XCTAssertTrue(context.contains("## Семья")); XCTAssertTrue(context.contains("notes_last_hour:"))
        let transcript = await tools.transcript()
        XCTAssertTrue(transcript.contains("### document_outline")); XCTAssertTrue(transcript.contains("### notes_last_hour"))
    }

    func testDeniedAccessNeverTouchesFiles() async {
        let tools = VikContextTools(document: document, source: current, isAllowed: { false }, files: { XCTFail("must not read"); return [] })
        do { _ = try await tools.preloaded(); XCTFail("must refuse") } catch {}
        do { _ = try await tools.read("notes_last_hour", arguments: "{}"); XCTFail("must refuse") } catch {}
        do { _ = try await tools.read("document_outline", arguments: "{}"); XCTFail("must refuse") } catch {}
    }

    // MARK: - Whole-library search, document search, follow-ups, secretary questions

    private func libraryNote(_ id: String, _ text: String, at date: Date, file: String? = nil) -> RecallNote {
        RecallNote(id: id, date: date, kind: "text", title: nil, summary: nil, text: text,
                   filePath: file ?? "/fixture/\(id).txt")
    }

    func testSearchNotesFindsOlderNotesExcludesCurrentAndReadsThem() async throws {
        let asked = try XCTUnwrap(FileStore.recordingDateFromFileName(current))
        let library = RecallLibrary([
            libraryNote("old-kiel", "Тётя Роза переехала в Киль весной.", at: asked.addingTimeInterval(-40 * 86400)),
            libraryNote("other", "Купить хлеб.", at: asked.addingTimeInterval(-86400)),
            libraryNote("self", "Алёна, где живёт тётя Роза? Киль?", at: asked, file: current.path),
        ])
        let tools = VikContextTools(document: "", source: current, asOf: asked.addingTimeInterval(5),
                                    isAllowed: { true }, files: { [] }, library: { library })
        let found = try object(await tools.read("search_notes", arguments: "{\"query\":\"Киль\"}"))
        let items = try XCTUnwrap(found["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["id"] as? String }, ["old-kiel"], "The asking note is not its own evidence")
        XCTAssertEqual(found["total"] as? Int, 1)
        let read = try object(await tools.read("read_note", arguments: "{\"id\":\"old-kiel\"}"))
        XCTAssertTrue((read["text"] as? String)?.contains("Тётя Роза") == true)
        let none = try await tools.read("search_notes", arguments: "{\"query\":\"Марсель\"}")
        XCTAssertTrue(none.hasPrefix("not_found"), none)
    }

    func testSearchNotesListsAPeriodWithoutQueryAndRejectsBadDates() async throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let asked = try XCTUnwrap(FileStore.recordingDateFromFileName(current))
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: asked)))
        let library = RecallLibrary([
            libraryNote("y1", "Утро вчера", at: yesterday.addingTimeInterval(9 * 3600)),
            libraryNote("y2", "Вечер вчера", at: yesterday.addingTimeInterval(22 * 3600)),
            libraryNote("before", "Позавчера", at: yesterday.addingTimeInterval(-3600)),
        ])
        let tools = VikContextTools(document: "", source: current, isAllowed: { true }, files: { [] }, library: { library })
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let text = day.string(from: yesterday)
        let listed = try object(await tools.read("search_notes", arguments: "{\"since\":\"\(text)\",\"until\":\"\(text)\"}"))
        XCTAssertEqual((listed["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["y2", "y1"])
        let bad = try await tools.read("search_notes", arguments: "{\"since\":\"вчера\"}")
        XCTAssertTrue(bad.hasPrefix("error:"), "A bad date is the model's to fix, not the exchange's end")
        let empty = try await tools.read("search_notes", arguments: "{}")
        XCTAssertTrue(empty.hasPrefix("error:"))
    }

    func testSearchWithoutLibrarySaysWhatToUseInstead() async throws {
        let tools = VikContextTools(document: "", source: current, isAllowed: { true }, files: { [] })
        let result = try await tools.read("search_notes", arguments: "{\"query\":\"Киль\"}")
        XCTAssertTrue(result.contains("notes_last_hour"), result)
    }

    func testDocumentFindReturnsBlocksWithHeadingPath() async throws {
        let tools = VikContextTools(document: document, source: current, isAllowed: { true }, files: { [] })
        let found = try object(await tools.read("document_find", arguments: "{\"queries\":[\"Киле\"]}"))
        let blocks = try XCTUnwrap(found["blocks"] as? [[String: Any]])
        let hit = try XCTUnwrap(blocks.first { ($0["text"] as? String)?.contains("Киле") == true })
        XCTAssertTrue((hit["path"] as? String)?.contains("Семья") == true)
        let bad = try await tools.read("document_find", arguments: "{\"queries\":[]}")
        XCTAssertTrue(bad.hasPrefix("error:"))
    }

    func testRecentRepliesAreReadOnlyOnRequest() async throws {
        let asked = Date()
        let entry = VikReplyLog.Entry(date: asked.addingTimeInterval(-60), request: "где живёт Роза", answer: "В Киле [N:old-kiel].")
        let tools = VikContextTools(document: "", source: current, asOf: asked, isAllowed: { true }, files: { [] },
                                    replies: { _ in [entry] })
        let context = try await tools.preloaded()
        XCTAssertFalse(context.contains("Роза"), "No implicit history: the first request carries no earlier exchange")
        let read = try await tools.read("my_recent_replies", arguments: "{}")
        XCTAssertTrue(read.contains("В Киле"))
    }

    func testReplyLogRoundTripsAndKeepsOnlyTheWindow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vik-replies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let fresh = VikReplyLog.text(date: now.addingTimeInterval(-600), source: "a.m4a", request: "вопрос", answer: "ответ\n\nвторой абзац",
                                     note: "заметка **Алёна:** в тексте", context: "")
        try Data(fresh.utf8).write(to: dir.appendingPathComponent("1.md"))
        let stale = VikReplyLog.text(date: now.addingTimeInterval(-3 * 3600), source: "b.m4a", request: "старый", answer: "старый ответ",
                                     note: "", context: "")
        try Data(stale.utf8).write(to: dir.appendingPathComponent("2.md"))
        try Data("# Чужой файл".utf8).write(to: dir.appendingPathComponent("3.md"))
        let entries = VikReplyLog.recent(before: now, directory: dir)
        XCTAssertEqual(entries.map(\.request), ["вопрос"])
        XCTAssertEqual(entries.first?.answer, "ответ\n\nвторой абзац")
    }

    func testSecretaryQuestionsListsOpenQuestionsWithOptions() async throws {
        let queue = """
        # Очередь

        ## Открытые вопросы

        - **Q12.** Когда переезд Розы? [S3]
          - A) Весной
          - B) Летом

        ## Закрытые

        - **Q3.** Старый вопрос.
        """
        let tools = VikContextTools(document: "", source: current, isAllowed: { true }, files: { [] }, reviewQueue: { queue })
        let listed = try object(await tools.read("secretary_questions", arguments: "{}"))
        let items = try XCTUnwrap(listed["items"] as? [[String: Any]])
        XCTAssertEqual(items.compactMap { $0["number"] as? Int }, [12])
        let missing = try await VikContextTools(document: "", source: current, isAllowed: { true }, files: { [] })
            .read("secretary_questions", arguments: "{}")
        XCTAssertTrue(missing.hasPrefix("not_found"))
    }

    func testDeniedAccessNeverLoadsTheLibrary() async {
        let tools = VikContextTools(document: "", source: current, isAllowed: { false }, files: { [] },
                                    library: { XCTFail("must not load"); return nil })
        do { _ = try await tools.read("search_notes", arguments: "{\"query\":\"x\"}"); XCTFail("must refuse") } catch {}
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

private actor ReadGate {
    var allowed = true
    var loading = false
    private var continuation: CheckedContinuation<RecallLibrary, Never>?
    func load() async -> RecallLibrary {
        loading = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func revoke() { allowed = false; continuation?.resume(returning: RecallLibrary([])); continuation = nil }
}
