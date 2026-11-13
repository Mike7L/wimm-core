import CryptoKit
import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure

final class MCPRecallServerTests: XCTestCase {

    private static let base = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private static let library: [RecallNote] = [
        RecallNote(
            id: "AAAA1111-0000-0000-0000-000000000001",
            date: base.addingTimeInterval(-10 * 86_400),
            kind: "audio",
            title: "Созвон с Петей",
            summary: "Обсудили релиз",
            text: "Петя сказал, что релиз HUD переносим на пятницу.",
            filePath: "/lib/a.m4a",
            // An old note edited an hour ago.
            updated: base.addingTimeInterval(-3600)
        ),
        RecallNote(
            id: "BBBB2222-0000-0000-0000-000000000002",
            date: base.addingTimeInterval(-3600),
            kind: "text",
            title: nil,
            summary: nil,
            text: "Купить молоко и хлеб",
            filePath: "/lib/b.txt",
            updated: base.addingTimeInterval(-3600)
        ),
        RecallNote(
            id: "CCCC3333-0000-0000-0000-000000000003",
            date: base.addingTimeInterval(-2 * 86_400),
            kind: "pdf",
            title: "Invoice",
            summary: nil,
            text: "",
            attachmentTexts: ["Total due: 42 EUR, release fee"],
            filePath: "/lib/c.pdf",
            updated: base.addingTimeInterval(-2 * 86_400)
        ),
    ]

    private func server() -> MCPRecallServer {
        MCPRecallServer(now: { Self.base }, isPrivate: { false }, library: { RecallLibrary(Self.library) })
    }

    private func call(_ json: String) async throws -> [String: Any] {
        let raw = await server().handle(line: json)
        let reply = try XCTUnwrap(raw)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func toolText(_ name: String, _ args: String) async throws -> (String, Bool) {
        let reply = try await call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testInitializeEchoesProtocolAndAdvertisesTools() async throws {
        let reply = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}"#)
        XCTAssertEqual(reply["id"] as? Int, 1)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let list = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((list["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Array(tools.compactMap { $0["name"] as? String }.prefix(4)), ["search_notes", "recent_notes", "changed_notes", "get_note"])
    }

    func testNotificationsGetNoReplyAndGarbageGetsParseError() async throws {
        let silent = await server().handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(silent)
        let garbageRaw = await server().handle(line: "not json")
        let garbage = try XCTUnwrap(garbageRaw)
        XCTAssertTrue(garbage.contains("-32700"))
        let unknown = try await call(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testSearchRequiresEveryTermAndRanksTitleFirst() async throws {
        let (text, isError) = try await toolText("search_notes", #"{"query":"релиз"}"#)
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("AAAA1111"))
        XCTAssertTrue(text.contains("переносим на пятницу"))

        let (none, _) = try await toolText("search_notes", #"{"query":"релиз молоко"}"#)
        XCTAssertTrue(none.hasPrefix("No notes match"))

        // Attachment text is searchable.
        let (pdf, _) = try await toolText("search_notes", #"{"query":"release fee"}"#)
        XCTAssertTrue(pdf.contains("CCCC3333"))
    }

    func testSearchHonoursDateWindow() async throws {
        let (text, _) = try await toolText("search_notes", #"{"query":"релиз","since":"2026-09-15"}"#)
        XCTAssertTrue(text.hasPrefix("No notes match"))
    }

    func testRecentNotesNewestFirstWithinDays() async throws {
        let (text, _) = try await toolText("recent_notes", #"{"days":3}"#)
        let b = try XCTUnwrap(text.range(of: "BBBB2222"))
        let c = try XCTUnwrap(text.range(of: "CCCC3333"))
        XCTAssertLessThan(b.lowerBound, c.lowerBound)
        XCTAssertFalse(text.contains("AAAA1111"))
    }

    /// Change order is oldest first, ties by id; the cursor resumes after
    /// the last note handed out, and an old note edited lately is listed.
    func testChangedNotesPagesOldestChangeFirstWithCursor() async throws {
        let (first, isError) = try await toolText("changed_notes", #"{"since":"2026-09-01","limit":2}"#)
        XCTAssertFalse(isError)
        XCTAssertTrue(first.contains("total: 3"))
        XCTAssertTrue(first.contains("remaining: 1"))
        // The header's next_cursor names the last id too; order is read from the list.
        let list = try XCTUnwrap(first.components(separatedBy: "\n\n").dropFirst().joined().nilIfEmpty)
        let c = try XCTUnwrap(list.range(of: "[CCCC3333"))
        let a = try XCTUnwrap(list.range(of: "[AAAA1111"))
        XCTAssertLessThan(c.lowerBound, a.lowerBound)
        XCTAssertFalse(first.contains("BBBB2222"))
        let cursor = try XCTUnwrap(first.split(separator: "\n").first { $0.hasPrefix("next_cursor: ") }?
            .dropFirst("next_cursor: ".count))

        let (second, _) = try await toolText("changed_notes", #"{"since":"2026-09-01","cursor":"\#(cursor)"}"#)
        XCTAssertTrue(second.contains("BBBB2222"))
        XCTAssertFalse(second.contains("[AAAA1111"))
        XCTAssertTrue(second.contains("remaining: 0"))

        // The cursor alone keeps the walk's since: total stays 3, not the whole library.
        let (alone, _) = try await toolText("changed_notes", #"{"cursor":"\#(cursor)"}"#)
        XCTAssertTrue(alone.contains("total: 3"))
        XCTAssertTrue(alone.contains("BBBB2222"))
        // Its next_cursor (even on an empty last page) still carries since.
        let last = try XCTUnwrap(alone.split(separator: "\n").first { $0.hasPrefix("next_cursor: ") }?
            .dropFirst("next_cursor: ".count))
        let (after, _) = try await toolText("changed_notes", #"{"cursor":"\#(last)"}"#)
        XCTAssertTrue(after.contains("total: 3"))
        XCTAssertTrue(after.contains("returned: 0"))

        // Only the two edited an hour ago are after a day ago.
        let (recent, _) = try await toolText("changed_notes", #"{"since":"2026-09-20T12:00:00Z"}"#)
        XCTAssertTrue(recent.contains("total: 2"))
        XCTAssertFalse(recent.contains("CCCC3333"))

        let (bad, badIsError) = try await toolText("changed_notes", #"{"cursor":"nonsense"}"#)
        XCTAssertTrue(badIsError)
        XCTAssertTrue(bad.contains("cursor"))
    }

    func testChangeCursorRoundTripsThroughItsToken() throws {
        let since = Date(timeIntervalSince1970: 1_789_000_000.5)
        let cursor = NoteRecall.ChangeCursor(
            updated: Date(timeIntervalSince1970: 1_790_000_000.123456), id: "AB.CD", since: since)
        let parsed = try XCTUnwrap(NoteRecall.ChangeCursor(token: cursor.token))
        XCTAssertEqual(parsed.id, "AB.CD")
        XCTAssertEqual(parsed.updated.timeIntervalSince1970, 1_790_000_000.123456, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(parsed.since).timeIntervalSince1970, since.timeIntervalSince1970, accuracy: 1e-6)

        let open = try XCTUnwrap(NoteRecall.ChangeCursor(token: NoteRecall.ChangeCursor(
            updated: since, id: "X").token))
        XCTAssertNil(open.since)
        XCTAssertEqual(open.id, "X")

        // A token from the first release (`<µs>.<id>`) still parses, without since.
        let legacy = try XCTUnwrap(NoteRecall.ChangeCursor(token: "1792782933815421.8DECF6EE-474F-63AF-CB51-B2B3AEF18029"))
        XCTAssertEqual(legacy.id, "8DECF6EE-474F-63AF-CB51-B2B3AEF18029")
        XCTAssertNil(legacy.since)
    }

    func testRestrictedSecretarySessionHidesAndRefusesBookkeepingWrites() async throws {
        let server = MCPRecallServer(isPrivate: { false }, allowedTools: ["get_note"], library: { RecallLibrary(Self.library) })
        let raw = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let reply = try XCTUnwrap(raw)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        let tools = try XCTUnwrap((json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["get_note"])
        let (text, error) = try await toolText(server, "mark_notes", #"{"marks":[]}"#)
        XCTAssertTrue(error)
        XCTAssertTrue(text.contains("disabled for this MCP session"))
        let (_, boundaryError) = try await toolText(server, "set_pass_boundary", #"{"as_of":"2026-10-27"}"#)
        XCTAssertTrue(boundaryError)
    }

    func testPageLimitCapsListingsAndIsAdvertised() async throws {
        let capped = MCPRecallServer(now: { Self.base }, isPrivate: { false }, pageLimit: 2, library: { RecallLibrary(Self.library) })
        let (text, _) = try await toolText(capped, "recent_notes", #"{"limit":50}"#)
        XCTAssertTrue(text.hasPrefix("3 note(s) in that window, showing 1–2; next offset 2"), text)
        let (search, _) = try await toolText(capped, "changed_notes", #"{}"#)
        XCTAssertTrue(search.contains("returned: 2"), search)
        let changed = MCPRecallServer.tools(pageLimit: 2).first { $0["name"] as? String == "changed_notes" }
        let limit = ((changed?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any])?["limit"] as? [String: Any]
        XCTAssertEqual(limit?["maximum"] as? Int, 2)
        XCTAssertNil(MCPRecallServer.pageLimit(from: ["WIMM_MCP_PAGE_LIMIT": "0"]))
        XCTAssertEqual(MCPRecallServer.pageLimit(from: ["WIMM_MCP_PAGE_LIMIT": "20"]), 20)
    }

    func testRecentAndSearchReportTotalsAndPageByOffset() async throws {
        let (first, _) = try await toolText("recent_notes", #"{"limit":2}"#)
        XCTAssertTrue(first.hasPrefix("3 note(s) in that window, showing 1–2; next offset 2"))
        let (second, _) = try await toolText("recent_notes", #"{"limit":2,"offset":2}"#)
        XCTAssertTrue(second.contains("showing 3–3"))
        XCTAssertTrue(second.contains("AAAA1111"))
        let (past, _) = try await toolText("recent_notes", #"{"offset":5}"#)
        XCTAssertTrue(past.hasPrefix("No more notes: 3"))

        let (search, _) = try await toolText("search_notes", #"{"query":"релиз"}"#)
        XCTAssertTrue(search.hasPrefix("1 note(s) match \"релиз\":"))
    }

    func testGetNoteByPrefixReturnsFullTextAndPath() async throws {
        let (text, isError) = try await toolText("get_note", #"{"id":"aaaa1111"}"#)
        XCTAssertFalse(isError)
        XCTAssertFalse(text.contains("file: /lib/a.m4a"))
        XCTAssertTrue(text.contains("Петя сказал"))
        XCTAssertTrue(text.contains("(captured)"))
        XCTAssertTrue(text.contains("--- primary text ("))

        let (missing, missingIsError) = try await toolText("get_note", #"{"id":"zzzz"}"#)
        XCTAssertTrue(missingIsError)
        XCTAssertTrue(missing.contains("No single note"))
    }

    func testBadArgumentsAreToolErrorsNotProtocolErrors() async throws {
        let (text, isError) = try await toolText("search_notes", #"{"query":"x","since":"yesterday"}"#)
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("since"))
    }

    func testPrivateModeRefusesToHandOutNoteText() async throws {
        let server = MCPRecallServer(now: { Self.base }, isPrivate: { true }, library: { RecallLibrary(Self.library) })
        let raw = await server.handle(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"get_note","arguments":{"id":"aaaa1111"}}}"#)
        let reply = try XCTUnwrap(raw)
        XCTAssertTrue(reply.contains("private mode"))
        XCTAssertTrue(reply.contains(#""isError":true"#))
        XCTAssertFalse(reply.contains("Петя"))
    }

    func testOccurrencesCountsCyrillicBytesAndHonoursCap() {
        XCTAssertEqual(NoteRecall.occurrences(of: "да", in: "да, да и ещё раз да"), 3)
        XCTAssertEqual(NoteRecall.occurrences(of: "да", in: "да, да и ещё раз да", cap: 2), 2)
        XCTAssertEqual(NoteRecall.occurrences(of: "нет", in: "да"), 0)
    }

    func testLibraryRoundTripsNotesAndCopiesFromEarlierLoad() {
        let first = RecallLibrary(Self.library)
        XCTAssertEqual((0..<first.count).map { first[$0] }, Self.library)

        var builder = RecallLibrary.Builder()
        builder.append(2, of: first)
        builder.append(Self.library[0])
        let second = builder.build()
        XCTAssertEqual(second[0], Self.library[2])
        XCTAssertEqual(second[1], Self.library[0])
        XCTAssertEqual(NoteRecall.search(second, query: "release fee").first?.note.id, Self.library[2].id)
        XCTAssertEqual(NoteRecall.find(second, id: "AAAA")?.id, Self.library[0].id)
    }

    /// The build child's records survive any chunking — split mid-line,
    /// mid-character — and text with newlines and U+2028 inside.
    func testBuildStreamReassemblesRecordsFromArbitraryChunks() throws {
        let tricky = RecallNote(
            id: "EEEE5555-0000-0000-0000-000000000005", date: Self.base, kind: "text",
            title: "Строка\u{2028}разрыв", summary: "Ä\nÖ", text: "one\ntwo\u{2028}ТРИ",
            attachmentTexts: ["", "Вложение"], filePath: "/lib/e.txt", updated: Self.base)
        let notes: [RecallNote?] = Self.library + [nil, tricky]
        let records = notes.enumerated().map { LibraryRecallSource.BuildRecord.encode(position: $0, note: $1) }
        var output = try JSONEncoder().encode(LibraryRecallSource.BuildHeader(
            count: records.count,
            rawBytes: records.reduce(0) { $0 + $1.rawBytes },
            foldedBytes: records.reduce(0) { $0 + $1.foldedBytes }))
        output.append(0x0A)
        for record in records { output.append(record.data) }

        var stream = LibraryRecallSource.BuildStream()
        var builder = RecallLibrary.Builder()
        var positions: [Int] = []
        var header: LibraryRecallSource.BuildHeader?
        for start in stride(from: 0, to: output.count, by: 7) {
            try stream.feed(output.subdata(in: start..<min(start + 7, output.count)), onHeader: { header = $0 }, onRecord: { record, payload in
                positions.append(record.position)
                if let layout = record.note { builder.append(layout, payload: payload) }
            })
        }
        XCTAssertTrue(stream.isComplete)
        XCTAssertEqual(header?.count, notes.count)
        XCTAssertEqual(positions, Array(notes.indices))
        let library = builder.build()
        let expected = RecallLibrary(notes.compactMap { $0 })
        XCTAssertEqual((0..<library.count).map { library[$0] }, (0..<expected.count).map { expected[$0] })
        XCTAssertEqual(library.folded, expected.folded)
        XCTAssertEqual(NoteRecall.search(library, query: "три").first?.note.id, tricky.id)

        var truncated = LibraryRecallSource.BuildStream()
        try truncated.feed(output.dropLast(3), onHeader: { _ in }, onRecord: { _, _ in })
        XCTAssertFalse(truncated.isComplete)
    }

    func testInflectedRussianAndPluralEnglishWordsStillMatch() {
        XCTAssertEqual(NoteRecall.stem("подписка"), "подписк")
        XCTAssertEqual(NoteRecall.stem("заметки"), "заметк")
        XCTAssertEqual(NoteRecall.stem("клод"), "клод")
        XCTAssertEqual(NoteRecall.stem("notes"), "note")
        XCTAssertEqual(NoteRecall.stem("class"), "class")
        let library = RecallLibrary([RecallNote(
            id: "DDDD4444-0000-0000-0000-000000000004", date: Self.base, kind: "audio",
            title: nil, summary: nil, text: "Клод делает акцию 10 евро за подписку.", filePath: "/lib/d.m4a")])
        XCTAssertEqual(NoteRecall.search(library, query: "подписка Клод").count, 1)
        XCTAssertTrue(NoteRecall.search(library, query: "подписка").first?.snippet.contains("подписку") ?? false)
    }

    // MARK: - Secretary fields

    private static let berlin = TimeZone(identifier: "Europe/Berlin")!

    private static let factNotes: [RecallNote] = [
        RecallNote(
            id: "EEEE5555-0000-0000-0000-000000000005", date: base.addingTimeInterval(-600), kind: "audio",
            title: "Вот идут последние", summary: nil, text: "Вот идут последние 15 минут",
            filePath: "/lib/long.m4a", duration: 4100.68, speech: "speech", chars: 27, device: "iPhone",
            updated: base.addingTimeInterval(-60)),
        RecallNote(
            id: "FFFF6666-0000-0000-0000-000000000006", date: base.addingTimeInterval(-1200), kind: "audio",
            title: nil, summary: nil, text: "No speech detected",
            filePath: "/lib/silent.m4a", duration: 0.007, speech: "skipped:no_live_speech", chars: 0, device: "macOS",
            updated: base.addingTimeInterval(-86_400)),
    ]

    private func factServer(_ notes: [RecallNote] = factNotes) -> MCPRecallServer {
        MCPRecallServer(now: { Self.base }, timeZone: Self.berlin, isPrivate: { false }, library: { RecallLibrary(notes) })
    }

    private func toolText(_ server: MCPRecallServer, _ name: String, _ args: String) async throws -> (String, Bool) {
        let raw = await server.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testListLinesCarryDurationSpeechCharsDeviceAndUpdated() async throws {
        let (text, isError) = try await toolText(factServer(), "recent_notes", #"{"limit":5}"#)
        XCTAssertFalse(isError)
        XCTAssertTrue(text.contains("duration: 4101 s (68 min) · speech: speech · chars: 27 · device: iPhone · updated: 2026-09-21 16:12:20"), text)
        XCTAssertTrue(text.contains("duration: 0.007 s · speech: skipped:no_live_speech · chars: 0 · device: macOS"), text)
        // The old header line is unchanged, so existing parsers still read it.
        XCTAssertTrue(text.contains("[EEEE5555-0000-0000-0000-000000000005] 2026-09-21 16:03 · audio · Вот идут последние"), text)

        let (search, _) = try await toolText(factServer(), "search_notes", #"{"query":"последние"}"#)
        XCTAssertTrue(search.contains("speech: speech · chars: 27"), search)
    }

    func testIncludeEmptyFalseHidesSilentAndSkippedRecordings() async throws {
        let (text, _) = try await toolText(factServer(), "recent_notes", #"{"include_empty":false}"#)
        XCTAssertTrue(text.contains("EEEE5555"))
        XCTAssertFalse(text.contains("FFFF6666"))
        XCTAssertTrue(RecallNote(id: "x", date: Self.base, kind: "audio", title: nil, summary: nil, text: "",
                                 filePath: "/x.m4a", speech: "speech", chars: 0).isEmpty)
        XCTAssertFalse(RecallNote(id: "x", date: Self.base, kind: "text", title: nil, summary: nil, text: "hi",
                                  filePath: "/x.txt", chars: 2).isEmpty)
    }

    func testLocalTimesWithoutZoneAreReadInTheServerTimeZone() throws {
        let server = factServer()
        let utc = ISO8601DateFormatter()
        // 21:46 in Berlin (CEST, +02:00) on 2026-10-23.
        XCTAssertEqual(try server.date("2026-10-23T21:46:00", name: "since"), utc.date(from: "2026-10-23T19:46:00Z"))
        XCTAssertEqual(try server.date("2026-10-23T21:46", name: "since"), utc.date(from: "2026-10-23T19:46:00Z"))
        XCTAssertEqual(try server.date("2026-10-23 21:46:30", name: "since"), utc.date(from: "2026-10-23T19:46:30Z"))
        XCTAssertEqual(try server.date("2026-10-23", name: "since"), utc.date(from: "2026-10-22T22:00:00Z"))
        // An explicit zone wins.
        XCTAssertEqual(try server.date("2026-10-23T21:46:00Z", name: "since"), utc.date(from: "2026-10-23T21:46:00Z"))
        XCTAssertEqual(try server.date("2026-10-23T21:46:00.5+02:00", name: "since")?.timeIntervalSince1970,
                       utc.date(from: "2026-10-23T19:46:00Z")!.timeIntervalSince1970 + 0.5)
        XCTAssertThrowsError(try server.date("23.10.2026", name: "since"))
    }

    func testSinceAcceptsLocalTimeAndUpdatedSinceFiltersOnWrites() async throws {
        // base - 600 s is 16:03:20 Berlin; base - 1200 s is 15:53:20.
        let (since, isError) = try await toolText(factServer(), "recent_notes", #"{"since":"2026-09-21T16:00:00"}"#)
        XCTAssertFalse(isError, since)
        XCTAssertTrue(since.contains("EEEE5555"))
        XCTAssertFalse(since.contains("FFFF6666"))

        let (updated, _) = try await toolText(factServer(), "recent_notes", #"{"updated_since":"2026-09-21 16:12:00"}"#)
        XCTAssertTrue(updated.contains("EEEE5555"))
        XCTAssertFalse(updated.contains("FFFF6666"))
        let (none, _) = try await toolText(factServer(), "search_notes", #"{"query":"последние","updated_since":"2026-09-21T16:13"}"#)
        XCTAssertTrue(none.hasPrefix("No notes match"), none)
    }

    func testGetNoteShowsSidecarHashAndEveryTextVariant() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-recall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("Wimm_2026-10-23_21-03-50_421FDA8E.m4a")
        try Data().write(to: media)
        let sidecar: [String: Any] = [
            "duration": 136.2,
            "origin": ["platform": "iPhone", "device": "iPhone15,2"],
            "syncUpdatedAt": "2026-10-24T10:59:10.878Z",
            "clipboardText": "secret-token-123",
            "transcription": [
                "provider": "gemini", "model": "gemini-flash-lite-latest", "speechStatus": "speech",
                "transcript": "Важная информация для разработки ВМ: новых собеседников.",
                "localTranscript": "важная информация для разработки вм новых собеседников",
            ],
            "noteCard": [
                "title": "Важная информация", "summary": "Про собеседников",
                "refined_text": "Важная информация для разработки Рим: новых священников.",
                "processed_at": "2026-10-23T19:06:06Z",
            ],
            "attachments": [["id": "a", "type": "image", "url": "x.png", "extractedText": "Скриншот: план",
                             "extractionProvider": "vision"],
                            ["id": "b", "type": "audio", "url": "answer.m4a", "extractedText": "Отправить гирю",
                             "extractionProvider": "parakeet", "journalPrompt": "Что осталось недоделанным?"]],
        ]
        let metaURL = FileStore.metadataURL(forRecordingURL: media)
        let data = try JSONSerialization.data(withJSONObject: sidecar)
        try data.write(to: metaURL)
        let note = RecallNote(
            id: "F622D8BC-0000-0000-0000-000000000007", date: Self.base, kind: "audio",
            title: "Важная информация", summary: "Про собеседников",
            text: "Важная информация для разработки ВМ: новых собеседников.",
            filePath: media.path, duration: 136.2, speech: "speech", chars: 57, device: "iPhone")

        let (text, isError) = try await toolText(factServer([note]), "get_note", #"{"id":"F622"}"#)
        XCTAssertFalse(isError, text)
        let expectedHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(factServer([note]).readNote(note, full: true).receipt?.sha256, expectedHash)
        XCTAssertFalse(text.contains("meta: "), text)
        XCTAssertFalse(text.contains("sha256: "), text)
        XCTAssertFalse(text.contains("\nupdated: "), text)
        XCTAssertTrue(text.contains("duration: 136 s (2 min)"), text)
        XCTAssertTrue(text.contains("speech: speech"), text)
        XCTAssertFalse(text.contains("transcription: "), text)
        XCTAssertTrue(text.contains("device: iPhone (iPhone15,2)"), text)
        XCTAssertFalse(text.contains("title_source: "), text)
        let stamp = MCPRecallServer.iso(Self.base)
        XCTAssertTrue(text.contains("--- primary transcript (gemini/gemini-flash-lite-latest, \(stamp), 7 words) ---\nВажная информация для разработки ВМ"), text)
        // Same words, different case/punctuation: collapsed, not repeated.
        XCTAssertTrue(text.contains("--- realtime transcript (\(stamp), 7 words) --- = transcript"), text)
        XCTAssertTrue(text.contains("--- refined (model) ---\nВажная информация для разработки Рим"), text)
        XCTAssertTrue(text.contains("--- attachment 1 (OCR, vision) ---\nСкриншот: план"), text)
        // An evening-journal answer names the question it answers.
        XCTAssertTrue(text.contains("--- attachment 2 (audio, parakeet, answer to «Что осталось недоделанным?») ---\nОтправить гирю"), text)
        // Raw sidecar fields are never handed out.
        XCTAssertFalse(text.contains("secret-token-123"))
        // 57 chars for 136 s of audio: flagged as partial.
        XCTAssertTrue(text.contains("coverage: ~4 s text for 136 s audio"), text)
    }

    func testSidecarSpeechVerdicts() {
        XCTAssertNil(RecallSidecar([:]).speech(isAudio: false))
        XCTAssertEqual(RecallSidecar(["transcription": ["speechStatus": "no_speech", "transcript": "[[NO_SPEECH]]"]]).speech(isAudio: true), "no_speech")
        XCTAssertEqual(RecallSidecar(["transcription": "Привет"]).speech(isAudio: true), "speech")
        XCTAssertEqual(RecallSidecar(["isStreamingSkipped": true, "streamingSkipReason": "silent_audio"]).speech(isAudio: true), "skipped:silent_audio")
        XCTAssertEqual(RecallSidecar(["streamingSkipReason": "silent_audio", "transcription": ["transcript": "Текст"]]).speech(isAudio: true), "speech")
        XCTAssertEqual(RecallSidecar([:]).speech(isAudio: true), "failed")
        XCTAssertEqual(RecallSidecar(["duration": 4100.68, "transcription": ["audioDurationSec": 1.0]]).duration, 4100.68)
        XCTAssertEqual(RecallSidecar(["streamingSkipDurationSec": 0.007]).duration, 0.007)
    }

    func testDurationFormattingKeepsTinyRecordingsVisible() {
        XCTAssertEqual(MCPRecallServer.seconds(0.007), "0.007 s")
        XCTAssertEqual(MCPRecallServer.seconds(12.34), "12.3 s")
        XCTAssertEqual(MCPRecallServer.seconds(4100.68), "4101 s (68 min)")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
