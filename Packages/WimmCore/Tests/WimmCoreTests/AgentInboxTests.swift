import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure

/// `wimm-cli inbox --hook`: the per-reader digest of changed notes. Runs over
/// invented notes in a temp directory; the cursor store sits beside them.
final class AgentInboxTests: XCTestCase {
    private var dir: URL!
    private var state: URL!
    private var now: Date!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-inbox-\(UUID().uuidString)")
        state = dir.appendingPathComponent("AgentState")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        now = Date().addingTimeInterval(5)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private final class Sink: @unchecked Sendable {
        var texts: [String] = []
        var fail = false
    }

    @discardableResult
    private func note(_ name: String, _ text: String, changed: Date, created: Date? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: created ?? changed, .modificationDate: changed], ofItemAtPath: url.path)
        return url
    }

    private func run(_ reader: String? = "session-a", at date: Date? = nil, isPrivate: Bool = false,
                     sink: Sink) async -> AgentInbox.Outcome {
        let directory = dir!
        return await AgentInbox.run(
            reader: reader, now: date ?? now, isPrivate: isPrivate,
            store: AgentInboxCursorStore(directory: state),
            listing: { LibraryRecallSource.modificationDates(in: [directory]) },
            write: { text in
                if sink.fail { throw POSIXError(.EPIPE) }
                sink.texts.append(text)
            })
    }

    private var cursors: AgentInboxCursorStore { AgentInboxCursorStore(directory: state) }

    func testNothingNewPrintsNothingAndMovesTheCursor() async throws {
        try note("Wimm_2026-11-18_09-00-00_AAAA0001.txt", "Старая заметка про огород", changed: now.addingTimeInterval(-7200))
        let sink = Sink()
        let outcome = await run(sink: sink)
        XCTAssertEqual(outcome, .nothingNew)
        XCTAssertTrue(sink.texts.isEmpty)
        XCTAssertEqual(try XCTUnwrap(cursors.cursor(for: "session-a")).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testNewNoteIsReportedOnceWithIdAndOneLinePreview() async throws {
        try note("Wimm_2026-11-18_09-00-00_AAAA0001.txt", "Старая заметка", changed: now.addingTimeInterval(-7200))
        let fresh = try note("Wimm_2026-11-20_10-00-00_BBBB0002.txt", "Купить рассаду\nи позвонить Вымышленову",
                             changed: now.addingTimeInterval(-600))
        let sink = Sink()
        let first = await run(sink: sink)
        XCTAssertEqual(first, .reported(1))
        let text = try XCTUnwrap(sink.texts.first)
        // The path as the listing spells it: the note id is derived from it.
        let library = await LibraryRecallSource.loadFiles([URL(fileURLWithPath: dir.path + "/" + fresh.lastPathComponent)])
        XCTAssertTrue(text.contains("[\(library[0].id)]"), text)
        XCTAssertTrue(text.contains("· new — Купить рассаду и позвонить Вымышленову"), text)
        XCTAssertFalse(text.contains("Старая заметка"))
        XCTAssertEqual(text.split(separator: "\n").count, 2)

        let second = await run(at: now.addingTimeInterval(60), sink: sink)
        XCTAssertEqual(second, .nothingNew)
        XCTAssertEqual(sink.texts.count, 1)
    }

    func testEditAfterTheLastReadIsReportedAsEdited() async throws {
        let url = try note("Wimm_2026-11-18_09-00-00_AAAA0001.txt", "Черновик", changed: now.addingTimeInterval(-7200))
        let sink = Sink()
        _ = await run(sink: sink)
        try Data("Черновик, дописанный позже".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(30)], ofItemAtPath: url.path)
        let outcome = await run(at: now.addingTimeInterval(60), sink: sink)
        XCTAssertEqual(outcome, .reported(1))
        XCTAssertTrue(try XCTUnwrap(sink.texts.last).contains("· edited — Черновик, дописанный позже"))
    }

    func testSidecarWriteIsReportedOnItsNoteAndStatusWritesAreNot() async throws {
        let old = now.addingTimeInterval(-7200)
        let audio = try note("Wimm_2026-11-18_09-00-00_AAAA0001.m4a", "", changed: old)
        try note("Wimm_2026-11-18_09-00-00_AAAA0001_micro.m4a", "", changed: old)
        let quiet = try note("Wimm_2026-11-18_10-00-00_AAAA0002.m4a", "", changed: old)
        func sidecar(_ media: URL, _ dict: [String: Any]) throws {
            let url = FileStore.metadataURL(forRecordingURL: media)
            try JSONSerialization.data(withJSONObject: dict).write(to: url)
            try FileManager.default.setAttributes([.creationDate: old, .modificationDate: now.addingTimeInterval(-60)],
                                                  ofItemAtPath: url.path)
        }
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        try sidecar(audio, ["transcription": ["transcript": "Вымышленный разговор про сад", "provider": "parakeet",
                                               "startedAt": stamp, "transcribedAt": stamp, "speechStatus": "speech"]])
        try sidecar(quiet, ["status": "done"])
        let sink = Sink()
        let outcome = await run(sink: sink)
        XCTAssertEqual(outcome, .reported(1))
        let text = try XCTUnwrap(sink.texts.first)
        XCTAssertTrue(text.contains("· audio · transcript — Вымышленный разговор про сад"), text)
    }

    func testFailedOutputLeavesTheCursorSoTheChangeComesAgain() async throws {
        try note("Wimm_2026-11-20_10-00-00_BBBB0002.txt", "Новая мысль", changed: now.addingTimeInterval(-600))
        let sink = Sink()
        sink.fail = true
        let failed = await run(sink: sink)
        XCTAssertEqual(failed, .outputFailed)
        XCTAssertNil(cursors.cursor(for: "session-a"))

        sink.fail = false
        let retried = await run(at: now.addingTimeInterval(60), sink: sink)
        XCTAssertEqual(retried, .reported(1))
        XCTAssertEqual(sink.texts.count, 1)
    }

    func testPrivateModePrintsNothingAndKeepsTheCursor() async throws {
        try note("Wimm_2026-11-20_10-00-00_BBBB0002.txt", "Личное", changed: now.addingTimeInterval(-600))
        let sink = Sink()
        let outcome = await run(isPrivate: true, sink: sink)
        XCTAssertEqual(outcome, .privateMode)
        XCTAssertTrue(sink.texts.isEmpty)
        XCTAssertNil(cursors.cursor(for: "session-a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testTwoReadersKeepSeparateCursors() async throws {
        try note("Wimm_2026-11-20_10-00-00_BBBB0002.txt", "Первая", changed: now.addingTimeInterval(-600))
        let a = Sink(), b = Sink()
        let firstA = await run("session-a", sink: a)
        XCTAssertEqual(firstA, .reported(1))
        try note("Wimm_2026-11-20_10-05-00_CCCC0003.txt", "Вторая", changed: now.addingTimeInterval(20))
        let later = now.addingTimeInterval(60)
        let secondA = await run("session-a", at: later, sink: a)
        let firstB = await run("session-b", at: later, sink: b)
        XCTAssertEqual(secondA, .reported(1))
        XCTAssertEqual(firstB, .reported(2))
        XCTAssertFalse(try XCTUnwrap(a.texts.last).contains("Первая"))
        XCTAssertTrue(try XCTUnwrap(b.texts.last).contains("Первая"))
        XCTAssertTrue(try XCTUnwrap(b.texts.last).contains("Вторая"))
    }

    func testOnlyItsOwnCursorFileIsWritten() async throws {
        let url = try note("Wimm_2026-11-20_10-00-00_BBBB0002.txt", "Новая мысль", changed: now.addingTimeInterval(-600))
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        _ = await run(sink: Sink())
        let written = try FileManager.default.contentsOfDirectory(atPath: state.path).sorted()
        XCTAssertEqual(written, [".inbox-cursors.lock", "inbox-cursors.json"])
        XCTAssertNil(AgentMarkStore(directory: state).pass())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["AgentState", url.lastPathComponent])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, before)
    }

    func testDigestStaysWithinItsSizeLimit() {
        let items = (0..<30).map { i in
            AgentInbox.Item(id: UUID().uuidString, date: now, kind: "audio", changes: [.new, .transcript],
                            preview: String(repeating: "слово ", count: 40))
        }
        let text = AgentInbox.render(items, total: 75, since: now.addingTimeInterval(-3600))
        XCTAssertLessThanOrEqual(text.count, AgentInbox.maxChars)
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, AgentInbox.maxItems + 2)
        XCTAssertTrue(text.contains("more: wimm MCP changed_notes since:"), text)
        XCTAssertEqual(AgentInbox.render([], total: 0, since: now), "")
    }

    func testReaderComesFromFlagThenEnvironmentThenHookInput() {
        let input = Data(#"{"session_id":"from-stdin","hook_event_name":"UserPromptSubmit"}"#.utf8)
        XCTAssertEqual(AgentInbox.reader(explicit: "flag", environment: ["CLAUDE_CODE_SESSION_ID": "env"], hookInput: input), "flag")
        XCTAssertEqual(AgentInbox.reader(explicit: nil, environment: ["WIMM_INBOX_READER": "own", "CLAUDE_CODE_SESSION_ID": "env"],
                                         hookInput: input), "own")
        XCTAssertEqual(AgentInbox.reader(explicit: nil, environment: ["CLAUDE_CODE_SESSION_ID": "env"], hookInput: input), "env")
        XCTAssertEqual(AgentInbox.reader(explicit: nil, environment: [:], hookInput: input), "from-stdin")
        XCTAssertNil(AgentInbox.reader(explicit: " ", environment: [:], hookInput: Data("not json".utf8)))
    }

    func testMissingReaderIsSilent() async {
        let sink = Sink()
        let outcome = await run(nil, sink: sink)
        XCTAssertEqual(outcome, .noReader)
        XCTAssertTrue(sink.texts.isEmpty)
    }
}
