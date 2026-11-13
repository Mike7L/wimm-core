import XCTest
@testable import WimmDomain

final class NoteShareSourceTests: XCTestCase {
    private let sharedAt = "2026-10-19T10:00:00Z"

    func testEmbeddedDateWinsOverFileDates() {
        let embedded = ISO8601.date(from: "2026-10-01T08:30:00Z")!
        let source = NoteShareSource(
            inbox: ["fileName": "Kitchen.m4a", "fileCreated": "2026-10-05T00:00:00Z", "sharedAt": sharedAt],
            embeddedDate: embedded,
            embeddedApp: "Voice Memos"
        )
        XCTAssertEqual(source.date, embedded)
        XCTAssertEqual(source.dateBasis, .embedded)
        XCTAssertEqual(source.displayString, "Voice Memos")
    }

    func testFileDatesFallBackToEarliestAndDropTempCopyStamps() {
        let old = NoteShareSource(
            inbox: [
                "fileCreated": "2026-09-02T12:00:00Z",
                "fileModified": "2026-09-03T12:00:00Z",
                "sharedAt": sharedAt,
            ],
            embeddedDate: nil,
            embeddedApp: nil
        )
        XCTAssertEqual(old.date, ISO8601.date(from: "2026-09-02T12:00:00Z"))
        XCTAssertEqual(old.dateBasis, .file)

        // The provider's temp copy is stamped seconds before the share.
        let tempCopy = NoteShareSource(
            inbox: ["fileCreated": "2026-10-19T09:59:58Z", "sharedAt": sharedAt],
            embeddedDate: nil,
            embeddedApp: nil
        )
        XCTAssertNil(tempCopy.date)
    }

    func testLinkShowsSiteAndRoundTripsThroughSidecar() {
        let source = NoteShareSource(
            inbox: ["url": "https://www.example.com/a?b=1", "title": "Page", "sharedAt": sharedAt],
            embeddedDate: nil,
            embeddedApp: nil
        )
        XCTAssertEqual(source.displayString, "example.com")
        let restored = NoteShareSource(metadata: [NoteShareSource.metadataKey: source.metadataValue])
        XCTAssertEqual(restored, source)
    }

    func testFileNameIsTheSourceWhenNothingElseIsKnown() {
        let source = NoteShareSource(inbox: ["fileName": "Report.pdf"], embeddedDate: nil, embeddedApp: nil)
        XCTAssertEqual(source.displayString, "Report.pdf")
        XCTAssertNil(NoteShareSource(metadata: [:]))
    }
}
