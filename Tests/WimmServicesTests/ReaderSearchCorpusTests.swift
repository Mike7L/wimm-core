import XCTest
import WimmDomain
import WimmInfrastructure

final class ReaderSearchCorpusTests: XCTestCase {
    private func note(
        id: UUID = UUID(), text: String = "", title: String? = nil,
        summary: String? = nil, metadata: String = "", filename: String = "note.txt",
        date: Date = Date(timeIntervalSince1970: 1), canceled: Bool = false
    ) -> Note {
        Note(id: id, index: 0, fileURL: URL(fileURLWithPath: "/tmp/\(filename)"),
             fileCreated: date, start: 0, end: 1, text: text, isFailed: false,
             metadataSearchText: metadata, hasRaw: false, title: title,
             summary: summary, isCanceled: canceled)
    }

    func testExplicitDeltaOnlyRebuildsChangedEntry() throws {
        var notes = (0..<100).map { note(text: "entry \($0)") }
        var corpus = ReaderSearchCorpus()
        _ = try corpus.update(notes: notes)
        notes[50].title = "unique changed title"
        let rebuilt = try corpus.update(notes: notes, changedIDs: [notes[50].id])
        XCTAssertEqual(rebuilt, 1)
        XCTAssertEqual(try corpus.searchIndices(query: "unique changed title"), [50])
    }

    func testMatchesExistingReaderAcrossScopesAndUnicode() throws {
        let id = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let notes = [
            note(id: id, text: "ПРОЕКТ ёж ёж Café cafe\u{301} a\u{301} x\u{301} 👩‍💻 👍🏽 🇩🇪 क्‍ष İSTANBUL Å Å 한 한 🇩🇪🇺",
                 title: "Title needle", summary: "Summary needle", metadata: "{\"nested\":{\"fullKey\":\"secret VALUE\"}}",
                 filename: "Импорт_2026.PDF"),
            note(text: "е ё Ё cafe 👩 👍 🇩 \u{301}क्ष"),
            note(text: "abcd\nproject plan", title: "left", summary: "right"),
            note(text: ""),
        ]
        let queries = ["ПРОЕКТ", "проек", "project plan", "plan project", " ", "", "  Café\n",
                       "cafe\u{301}", "cafe", "a", "a\u{301}", "\u{301}", "x", "x\u{301}",
                       "ё", "ё", "е", "👩", "👩‍💻", "💻", "👍", "🏽", "👍🏽", "🇩", "🇩🇪",
                       "क", "क्ष", "क्‍ष", "i", "İ", "i\u{307}", "Å", "a\u{30a}", "한", "한", "ᄒ", "🇺", "🇪🇺", "TITLE", "summary", "fullkey", "secret value",
                       "импорт_2026.pdf", "5678-1234", "1234567890AB", "needleSummary", "leftright", "missing"]
        var corpus = ReaderSearchCorpus()
        try corpus.update(notes: notes)
        for flags in 0..<16 {
            for query in queries {
                let expected = NotesQueryService().searchIndices(
                    notes: notes, query: query, searchInTitle: flags & 1 != 0,
                    searchInSummary: flags & 2 != 0, searchInText: flags & 4 != 0,
                    searchInId: flags & 8 != 0)
                let actual = try corpus.searchIndices(
                    query: query, searchInTitle: flags & 1 != 0,
                    searchInSummary: flags & 2 != 0, searchInText: flags & 4 != 0,
                    searchInId: flags & 8 != 0)
                XCTAssertEqual(actual, expected, "query=\(query), flags=\(flags)")
            }
        }
    }

    func testIncrementalReplacementReorderDeletionAndCompaction() throws {
        let a = note(text: "old value", metadata: String(repeating: "payload", count: 10_000))
        let b = note(text: "second")
        var corpus = ReaderSearchCorpus()
        XCTAssertEqual(try corpus.update(notes: [a, b]), 2)
        let before = corpus.byteCount
        XCTAssertEqual(try corpus.update(notes: [a, b]), 0)
        XCTAssertEqual(try corpus.update(notes: [b, a]), 0)
        XCTAssertEqual(try corpus.searchIndices(query: "old value"), [1])
        var edited = a
        edited.title = "new title"
        XCTAssertEqual(try corpus.update(notes: [b, edited]), 1)
        XCTAssertEqual(try corpus.searchIndices(query: "new title"), [1])
        XCTAssertEqual(try corpus.update(notes: [b]), 0)
        XCTAssertLessThan(corpus.byteCount, before / 100)
        XCTAssertEqual(try corpus.searchIndices(query: "old value"), [])
        XCTAssertEqual(corpus.count, 1)
        XCTAssertEqual(try corpus.update(notes: []), 0)
        XCTAssertEqual(corpus.byteCount, 0)
    }

    func testNormalizedMetadataDoesNotAddAnotherFullPayload() throws {
        let value = note(metadata: String(repeating: "already lowercased проект ", count: 40_000))
        var corpus = ReaderSearchCorpus()
        try corpus.update(notes: [value])
        XCTAssertGreaterThan(corpus.byteCount, 1_000_000)
        XCTAssertLessThan(corpus.additionalByteCount, 1_000)
        XCTAssertEqual(try corpus.searchIndices(query: "проект"), [0])
        // A disk reload can supply equal text with entirely new String storage.
        let replacement = note(id: value.id, metadata: String(decoding: Array(value.metadataSearchText.utf8), as: UTF8.self))
        XCTAssertEqual(try corpus.update(notes: [replacement]), 0)
        XCTAssertLessThan(corpus.additionalByteCount, 1_000)
        // Canonically equal but byte-different replacement must not reuse wrong
        // grapheme offsets or treat non-NFC input as a prepared byte buffer.
        let composed = note(id: value.id, metadata: "café 👩‍💻")
        try corpus.update(notes: [composed])
        let decomposed = note(id: value.id, metadata: "cafe\u{301} 👩‍💻")
        XCTAssertEqual(try corpus.update(notes: [decomposed]), 0)
        XCTAssertEqual(try corpus.searchIndices(query: "café"), [0])
        XCTAssertEqual(try corpus.searchIndices(query: "👩"), [])
    }

    func testWorkerSharesMatchesButAppliesCurrentFlagsAndOrder() async throws {
        let a = note(text: "target", date: Date(timeIntervalSince1970: 1))
        let b = note(text: "target", date: Date(timeIntervalSince1970: 2), canceled: true)
        let c = note(text: "unrelated")
        let worker = ReaderSearchWorker()
        var filter = NoteFilter(query: "target", onlyMatches: true)
        let first = try await worker.search(notes: [a, b, c], revision: 1, filter: filter)
        XCTAssertEqual(first.hits, [0, 1], "Navigation searches the whole note array")
        XCTAssertEqual(first.visibleIndices, [0], "List applies non-text filters")
        XCTAssertEqual(first.rebuiltEntries, 3)
        filter.showCanceledNotes = true
        let flagsChanged = try await worker.search(notes: [a, b, c], revision: 1, filter: filter)
        XCTAssertEqual(flagsChanged.visibleIndices, [1, 0])
        XCTAssertEqual(flagsChanged.rebuiltEntries, 0)
        let reordered = try await worker.search(notes: [c, b, a], revision: 2, filter: filter)
        XCTAssertEqual(reordered.rebuiltEntries, 0)
        XCTAssertEqual(reordered.hits, [1, 2])
        XCTAssertEqual(reordered.visibleIndices, [1, 2])
        filter.query = "   "
        let empty = try await worker.search(notes: [c, b, a], revision: 2, filter: filter)
        XCTAssertEqual(empty.hits, [])
        XCTAssertEqual(Set(empty.visibleIndices), [0, 1, 2])
    }

    func testCancellationDoesNotCommitPartialRevision() async throws {
        let worker = ReaderSearchWorker()
        let original = [note(text: "original")]
        _ = try await worker.search(notes: original, revision: 1, filter: NoteFilter(query: "original"))
        let replacement = [note(text: "replacement")]
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.search(notes: replacement, revision: 2, filter: NoteFilter(query: "replacement"))
        }
        do {
            _ = try await canceled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        let result = try await worker.search(notes: original, revision: 1, filter: NoteFilter(query: "original"))
        XCTAssertEqual(result.hits, [0])
        XCTAssertEqual(result.rebuiltEntries, 0)
    }
}
