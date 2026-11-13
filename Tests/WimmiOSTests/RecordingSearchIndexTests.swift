import XCTest
import WimmDomain
@testable import WimmiOSApp

final class RecordingSearchIndexTests: XCTestCase {
    private func recording(_ id: String, _ date: Date, title: String = "", summary: String = "", refined: String? = nil) -> Recording {
        var card: NoteCard?
        if !summary.isEmpty || refined != nil {
            card = NoteCard(note_file: id, lang: nil, title: "", summary: summary, refined_text: refined)
        }
        return Recording(
            id: id,
            fileURL: URL(fileURLWithPath: "/tmp/\(id)"),
            timestamp: date,
            durationSeconds: 0,
            note: card,
            titlePreview: title
        )
    }

    func testMatchesFoldedFieldsAndGroupsByDayNewestFirst() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date()).addingTimeInterval(3600 * 12)
        let yesterday = today.addingTimeInterval(-86_400)
        let items = [
            recording("a.m4a", today, title: "Встреча: Анна и Пётр"),
            recording("b.m4a", today.addingTimeInterval(-60), summary: "про бюджет"),
            recording("c.txt", yesterday, refined: "Длинный текст: АННА звонила"),
            recording("d.m4a", yesterday, title: "Ан", summary: "на"),
        ]
        let index = RecordingSearchIndex()

        let query = RecordingSearchIndex.normalize("  анна ")
        let hitsResult = await index.groups(recordings: items, revision: 1, query: query)
        let hits = try XCTUnwrap(hitsResult)
        XCTAssertEqual(hits.map { $0.recordings.map(\.id) }, [["a.m4a"], ["c.txt"]])
        XCTAssertEqual(hits.map(\.id), [calendar.startOfDay(for: today), calendar.startOfDay(for: yesterday)])

        // "Ан" + "на" must not match "анна" across two fields.
        XCTAssertFalse(hits.flatMap(\.recordings).contains { $0.id == "d.m4a" })

        let allResult = await index.groups(recordings: items, revision: 1, query: "")
        let all = try XCTUnwrap(allResult)
        XCTAssertEqual(all.map { $0.recordings.map(\.id) }, [["a.m4a", "b.m4a"], ["c.txt", "d.m4a"]])
    }

    func testRefoldsWhenRevisionChanges() async throws {
        let now = Date()
        let index = RecordingSearchIndex()
        let before = [recording("a.m4a", now, title: "старое")]
        let missResult = await index.groups(recordings: before, revision: 1, query: "новое")
        let miss = try XCTUnwrap(missResult)
        XCTAssertTrue(miss.isEmpty)

        let after = [recording("a.m4a", now, title: "новое")]
        let hitResult = await index.groups(recordings: after, revision: 2, query: "новое")
        let hit = try XCTUnwrap(hitResult)
        XCTAssertEqual(hit.flatMap(\.recordings).map(\.id), ["a.m4a"])
    }
}
