import XCTest
import WimmDomain
import WimmInfrastructure

final class NotesQueryServiceTests: XCTestCase {
    private let service = NotesQueryService()

    func testTextMatchIndicesCaseInsensitive() {
        let notes = [
            makeNote(text: "Apple pie", created: Date()),
            makeNote(text: "banana", created: Date()),
            makeNote(text: "GREEN apple", created: Date())
        ]

        let hits = service.textMatchIndices(notes: notes, query: "apple")
        XCTAssertEqual(hits, [0, 2])
    }

    func testTextMatchIndicesMatchesByPartialId() {
        let targetId = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let notes = [
            makeNote(id: UUID(), text: "no match", created: Date()),
            makeNote(id: targetId, text: "another text", created: Date()),
            makeNote(id: UUID(), text: "still no", created: Date())
        ]

        let hits = service.textMatchIndices(notes: notes, query: "5678-1234")
        XCTAssertEqual(hits, [1])
    }

    func testTextMatchIndicesMatchesByTitleAndSummary() {
        let notes = [
            makeNote(text: "no match", created: Date(), title: "Weekly planning"),
            makeNote(text: "also no match", created: Date(), summary: "Decision about roadmap"),
            makeNote(text: "still no", created: Date())
        ]

        let titleHits = service.textMatchIndices(notes: notes, query: "planning")
        XCTAssertEqual(titleHits, [0])

        let summaryHits = service.textMatchIndices(notes: notes, query: "roadmap")
        XCTAssertEqual(summaryHits, [1])
    }

    func testSearchIndicesRespectsScopeFlags() {
        let targetId = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let notes = [
            makeNote(id: UUID(), text: "text-only", created: Date(), title: "title-only", summary: "summary-only"),
            makeNote(id: targetId, text: "body target", created: Date(), title: "Weekly target", summary: "Roadmap target")
        ]

        let titleOnly = service.searchIndices(
            notes: notes,
            query: "weekly",
            searchInTitle: true,
            searchInSummary: false,
            searchInText: false,
            searchInId: false
        )
        XCTAssertEqual(titleOnly, [1])

        let summaryOnly = service.searchIndices(
            notes: notes,
            query: "roadmap",
            searchInTitle: false,
            searchInSummary: true,
            searchInText: false,
            searchInId: false
        )
        XCTAssertEqual(summaryOnly, [1])

        let contentOnly = service.searchIndices(
            notes: notes,
            query: "body target",
            searchInTitle: false,
            searchInSummary: false,
            searchInText: true,
            searchInId: false
        )
        XCTAssertEqual(contentOnly, [1])

        let idOnly = service.searchIndices(
            notes: notes,
            query: "5678-1234",
            searchInTitle: false,
            searchInSummary: false,
            searchInText: false,
            searchInId: true
        )
        XCTAssertEqual(idOnly, [1])
    }

    func testNextSearchIndexWraps() {
        let hits = [2, 5, 9]
        XCTAssertEqual(service.nextSearchIndex(hits: hits, currentIndex: nil), 2)
        XCTAssertEqual(service.nextSearchIndex(hits: hits, currentIndex: 2), 5)
        XCTAssertEqual(service.nextSearchIndex(hits: hits, currentIndex: 9), 2)
        XCTAssertNil(service.nextSearchIndex(hits: [], currentIndex: 1))
    }

    func testComputeVisibleIndicesFiltersAndSortsByDateDescending() {
        let now = Date()
        let older = now.addingTimeInterval(-3600)
        let newest = now.addingTimeInterval(3600)

        let notes = [
            makeNote(text: "target one", created: older),
            makeNote(text: "target two", created: newest),
            makeNote(text: "target three", created: now),
            makeNote(text: "unrelated", created: now)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "target",
                onlyMatches: true,
                failedOnly: false,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: false,
                unprocessedOnly: false,
                showArtifacts: true,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [1, 2, 0], "Should keep text matches and order by newest first")
    }

    func testComputeVisibleIndicesSuspectedNoSpeechOnly() {
        let now = Date()
        let notes = [
            makeNote(text: "real speech", created: now),
            makeNote(text: "fabricated on silence", created: now.addingTimeInterval(-10), suspectedNoSpeech: true)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "",
                onlyMatches: false,
                failedOnly: false,
                suspectedNoSpeechOnly: true,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: false,
                unprocessedOnly: false,
                showArtifacts: true,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [1], "Only the suspected-no-speech note should remain")
    }

    func testComputeVisibleIndicesImportedOnly() {
        let now = Date()
        let notes = [
            makeNote(text: "captured", created: now),
            makeNote(text: "imported", created: now.addingTimeInterval(-10), isImported: true)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "",
                onlyMatches: false,
                failedOnly: false,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: false,
                unprocessedOnly: false,
                importedOnly: true,
                showArtifacts: true,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [1])
    }

    func testNoteCodableRoundTripsSuspectedNoSpeech() throws {
        let note = makeNote(text: "x", created: Date(), suspectedNoSpeech: true)
        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: data)
        XCTAssertTrue(decoded.suspectedNoSpeech)
        // Legacy notes (key absent) default to false.
        XCTAssertFalse(makeNote(text: "y", created: Date()).suspectedNoSpeech)
    }

    func testComputeVisibleIndicesHidesArtifactsByDefault() {
        let now = Date()
        let notes = [
            makeNote(text: "artifact", created: now, isArtifact: true),
            makeNote(text: "regular", created: now.addingTimeInterval(-10), isArtifact: false)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "",
                onlyMatches: false,
                failedOnly: false,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: false,
                unprocessedOnly: false,
                showArtifacts: false,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [1], "Artifacts should be excluded when showArtifacts=false")
    }

    func testComputeVisibleIndicesFilterArtifactsOnly() {
        let now = Date()
        let notes = [
            makeNote(text: "artifact", created: now, isArtifact: true),
            makeNote(text: "regular", created: now.addingTimeInterval(-10), isArtifact: false)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "",
                onlyMatches: false,
                failedOnly: false,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: true,
                unprocessedOnly: false,
                showArtifacts: false,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [0], "filterArtifactsOnly must return only artifacts")
    }

    func testComputeVisibleIndicesDraftsOnlyExcludesArtifacts() {
        let now = Date()
        let notes = [
            makeNote(text: "draft-regular", created: now, isArtifact: false, isDraft: true),
            makeNote(text: "draft-artifact", created: now.addingTimeInterval(-5), isArtifact: true, isDraft: true),
            makeNote(text: "regular", created: now.addingTimeInterval(-10), isArtifact: false, isDraft: false)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "",
                onlyMatches: false,
                failedOnly: false,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: true,
                artifactsOnly: false,
                unprocessedOnly: false,
                showArtifacts: true,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [0], "draft filter should keep only non-artifact drafts")
    }

    func testComputeVisibleIndicesWithShotOnlyAndHideCanceled() {
        let now = Date()
        let notes = [
            makeNote(text: "shot-ok", created: now, isCanceled: false, hasScreenshot: true),
            makeNote(text: "shot-canceled", created: now.addingTimeInterval(-5), isCanceled: true, hasScreenshot: true),
            makeNote(text: "no-shot", created: now.addingTimeInterval(-10), isCanceled: false, hasScreenshot: false)
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "",
                onlyMatches: false,
                failedOnly: false,
                withScreenshotOnly: true,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: false,
                unprocessedOnly: false,
                showArtifacts: true,
                showCanceledNotes: false
            )
        )

        XCTAssertEqual(indices, [0], "withShotOnly should keep screenshot notes and hide canceled when requested")
    }

    func testComputeVisibleIndicesMatchesByFullIdWhenOnlyMatchesEnabled() {
        let now = Date()
        let targetId = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let notes = [
            makeNote(id: UUID(), text: "one", created: now.addingTimeInterval(-10)),
            makeNote(id: targetId, text: "two", created: now),
            makeNote(id: UUID(), text: "three", created: now.addingTimeInterval(-20))
        ]

        let indices = service.computeVisibleIndices(
            notes: notes,
            filter: NoteFilter(
                query: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                onlyMatches: true,
                failedOnly: false,
                withScreenshotOnly: false,
                insightsOnly: false,
                favoritesOnly: false,
                draftsOnly: false,
                artifactsOnly: false,
                unprocessedOnly: false,
                showArtifacts: true,
                showCanceledNotes: true
            )
        )

        XCTAssertEqual(indices, [1])
    }

    private func makeNote(
        id: UUID = UUID(),
        text: String,
        created: Date,
        title: String? = nil,
        summary: String? = nil,
        projectId: String? = nil,
        isArtifact: Bool = false,
        isDraft: Bool = false,
        isInsight: Bool = false,
        isLiked: Bool = false,
        isUnprocessed: Bool = false,
        isCanceled: Bool = false,
        hasScreenshot: Bool = false,
        isFailed: Bool = false,
        suspectedNoSpeech: Bool = false,
        isImported: Bool = false
    ) -> Note {
        return Note(
            id: id,
            index: 0,
            fileURL: URL(fileURLWithPath: "/tmp/\(id.uuidString).txt"),
            fileCreated: created,
            start: 0,
            end: 60,
            text: text,
            isFailed: isFailed,
            isImported: isImported,
            screenshotURL: hasScreenshot ? URL(fileURLWithPath: "/tmp/\(id.uuidString).png") : nil,
            hasRaw: false,
            projectId: projectId,
            title: title,
            summary: summary,
            isArtifact: isArtifact,
            isLiked: isLiked,
            isDraft: isDraft,
            isInsight: isInsight,
            suspectedNoSpeech: suspectedNoSpeech,
            isUnprocessed: isUnprocessed,
            isCanceled: isCanceled
        )
    }
}
