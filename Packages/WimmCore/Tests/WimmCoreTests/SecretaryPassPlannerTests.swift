import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryPassPlannerTests: XCTestCase {
    private var directory: URL!
    private var store: AgentMarkStore!
    private let boundary = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("planner-\(UUID().uuidString)")
        store = AgentMarkStore(directory: directory)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func note(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).m4a") }

    private func mark(_ name: String, text: String = "t", analysis: String = "a") -> (String, AgentMarkStore.Mark?) {
        (name + ".m4a", AgentMarkStore.Mark(status: .applied, source: nil, comment: nil, markedAt: boundary,
                                            noteId: name, sidecarSHA256: nil, text: text, analysis: analysis))
    }

    private func scan(changes: [String: TimeInterval], fingerprints: [String: NoteFingerprint] = [:],
                      kinds: [String: [NoteChangeKind]] = [:]) async -> SecretaryPassScan? {
        await SecretaryPassPlanner.scan(
            marks: store, recordings: { changes.keys.sorted().map(self.note) },
            lastChange: { changes[$0.deletingPathExtension().lastPathComponent].map { Date(timeIntervalSince1970: $0) } },
            fingerprint: { fingerprints[$0.deletingPathExtension().lastPathComponent] ?? NoteFingerprint(text: "t", analysis: "a") },
            kinds: { url, _ in kinds[url.deletingPathExtension().lastPathComponent] ?? [.metadata] })
    }

    func testNoBoundaryMeansUnknown() async {
        let none = await scan(changes: ["a": 2_000_000])
        XCTAssertNil(none)
    }

    func testHostCanPlanTheFirstBoundaryWithoutSkippingUnreviewedNotes() async throws {
        let found = await SecretaryPassPlanner.scan(marks: store, initialBoundary: .distantPast,
            recordings: { [self.note("unreviewed")] }, lastChange: { _ in self.boundary })
        let scan = try XCTUnwrap(found)
        XCTAssertEqual(scan.pending, 1)
        XCTAssertEqual(SecretaryPassPlanner.advancedBoundary(after: scan, started: boundary.addingTimeInterval(100)), boundary)
        XCTAssertNil(store.pass(), "planning itself never writes a boundary")
    }

    func testMarkedUnchangedNotesAreNotPendingButUnmarkedAndEditedAre() async throws {
        try store.setPass(.init(asOf: boundary, cursor: nil, comment: nil, setAt: boundary))
        try store.update(Dictionary(uniqueKeysWithValues: [mark("done"), mark("edited"), mark("reanalyzed"), mark("ocr")]))
        let found = await scan(
            changes: ["old": 500_000, "done": 2_000_000, "edited": 2_100_000, "fresh": 2_200_000, "reanalyzed": 2_300_000, "ocr": 2_400_000],
            fingerprints: ["edited": NoteFingerprint(text: "other", analysis: "a"),
                           "reanalyzed": NoteFingerprint(text: "t", analysis: "new"),
                           "ocr": NoteFingerprint(text: "ocr text", analysis: "a")],
            kinds: ["edited": [.edited], "ocr": [.metadata], "reanalyzed": [.analysis]])
        let result = try XCTUnwrap(found)
        XCTAssertEqual(result.pending, 2, "old is before the boundary; done is unchanged; reanalyzed and ocr moved no transcript and no edit")
        XCTAssertEqual(result.oldestPending, Date(timeIntervalSince1970: 2_100_000))
    }

    /// The planner counts what preparation would offer: a settled note whose re-run only moved
    /// punctuation stays settled (it pinned the real boundary for weeks), a pending or failed one does not.
    func testPunctuationOnlyRerunOfSettledNoteDoesNotPinTheBoundary() async throws {
        try store.setPass(.init(asOf: boundary, cursor: nil, comment: nil, setAt: boundary))
        func marked(_ name: String, _ status: AgentMarkStore.Mark.Status) -> (String, AgentMarkStore.Mark?) {
            (name + ".m4a", .init(status: status, source: nil, markedAt: boundary, noteId: name,
                                  text: "t", analysis: "a", wording: "w"))
        }
        try store.update(Dictionary(uniqueKeysWithValues: [marked("noise", .noise), marked("applied", .applied),
                                                           marked("pending", .pending), marked("reworded", .applied)]))
        let punctuated = NoteFingerprint(text: "t2", analysis: "a", wording: "w")
        let found = await scan(
            changes: ["noise": 2_000_000, "applied": 2_100_000, "pending": 2_300_000, "reworded": 2_400_000, "fresh": 2_500_000],
            fingerprints: ["noise": punctuated, "applied": punctuated, "pending": punctuated,
                           "reworded": NoteFingerprint(text: "t3", analysis: "a", wording: "other words")],
            kinds: ["noise": [.transcript], "applied": [.transcript], "pending": [.transcript], "reworded": [.transcript]])
        let result = try XCTUnwrap(found)
        XCTAssertEqual(result.pending, 3, "pending, reworded and fresh; the punctuation-only settled notes are not")
        XCTAssertEqual(result.oldestPending, Date(timeIntervalSince1970: 2_300_000))
    }

    func testSessionJournalDoesNotPinTheBoundary() async throws {
        try store.setPass(.init(asOf: boundary, cursor: nil, comment: nil, setAt: boundary))
        let found = await SecretaryPassPlanner.scan(
            marks: store, recordings: { [self.note("journal"), self.note("fresh")] },
            lastChange: { $0.lastPathComponent == "journal.m4a" ? Date(timeIntervalSince1970: 2_000_000) : Date(timeIntervalSince1970: 2_500_000) },
            journal: { $0.lastPathComponent == "journal.m4a" })
        let result = try XCTUnwrap(found)
        XCTAssertEqual(result.pending, 1)
        XCTAssertEqual(result.oldestPending, Date(timeIntervalSince1970: 2_500_000))
    }

    func testNothingPendingWhenEverythingIsMarked() async throws {
        try store.setPass(.init(asOf: boundary, cursor: nil, comment: nil, setAt: boundary))
        try store.update(Dictionary(uniqueKeysWithValues: [mark("done")]))
        let found = await scan(changes: ["done": 2_000_000])
        let result = try XCTUnwrap(found)
        XCTAssertEqual(result.pending, 0)
        XCTAssertNil(result.oldestPending)
    }

    func testDiskScanChecksTypedEditsAndTranscriptChangesBeforeAdvancingBoundary() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try store.setPass(.init(asOf: boundary, cursor: nil, comment: nil, setAt: boundary))
        let start = boundary.addingTimeInterval(100)
        let media = ["sync.m4a", "transcript.m4a", "typed.txt", "unchanged.m4a", "unmarked.m4a"]
            .map { directory.appendingPathComponent($0) }
        var marks: [String: AgentMarkStore.Mark?] = [:]
        for url in media {
            try Data("original".utf8).write(to: url)
            let fp = NoteFingerprint.read(forRecordingURL: url)
            if url.lastPathComponent != "unmarked.m4a" {
                marks[url.lastPathComponent] = .init(status: .applied, source: nil, markedAt: boundary,
                    noteId: url.lastPathComponent, text: fp.text, analysis: fp.analysis)
            }
        }
        try store.update(marks)
        FileStore.upsertMetadata(for: media[0], updates: ["transcription": "legacy text with no run timestamp"])
        FileStore.upsertMetadata(for: media[1], updates: [
            "transcription": ["transcript": "new transcript", "startedAt": ISO8601.string(from: boundary)]
        ])
        try Data("edited".utf8).write(to: media[2])
        FileStore.upsertMetadata(for: media[3], updates: [
            "transcription": ["startedAt": ISO8601.string(from: boundary)]
        ])
        for (index, url) in media.enumerated() {
            let date = boundary.addingTimeInterval(Double(index))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            let sidecar = FileStore.metadataURL(forRecordingURL: url)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sidecar.path)
            }
        }

        let result = await SecretaryPassPlanner.scan(marks: store, recordings: { media })
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.pending, 3)
        XCTAssertEqual(scan.unmarked, 1)
        XCTAssertEqual(scan.oldestPending, boundary.addingTimeInterval(1))
        XCTAssertEqual(SecretaryPassPlanner.advancedBoundary(after: scan, started: start), scan.oldestPending)
    }

    func testBoundaryAdvancesToStartButNeverPastAPendingNote() {
        let clean = SecretaryPassScan(boundary: boundary, pending: 0, oldestPending: nil)
        XCTAssertEqual(SecretaryPassPlanner.advancedBoundary(after: clean, started: Date(timeIntervalSince1970: 3_000_000)),
                       Date(timeIntervalSince1970: 3_000_000))
        let left = SecretaryPassScan(boundary: boundary, pending: 1, oldestPending: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertEqual(SecretaryPassPlanner.advancedBoundary(after: left, started: Date(timeIntervalSince1970: 3_000_000)),
                       Date(timeIntervalSince1970: 2_000_000))
        XCTAssertNil(SecretaryPassPlanner.advancedBoundary(after: clean, started: Date(timeIntervalSince1970: 500_000)),
                     "never backwards")
    }
}
