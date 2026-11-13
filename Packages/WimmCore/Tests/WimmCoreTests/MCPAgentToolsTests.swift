import CryptoKit
import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure

/// The write half of the MCP server: agent marks, the pass boundary and
/// retranscription requests. Runs over real files in a temp directory,
/// because marks fingerprint what is on disk.
final class MCPAgentToolsTests: XCTestCase {

    private static let base = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21

    private var dir: URL!
    private var audio: URL!
    private var image: URL!
    private var workerStarts: Counter!

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        audio = dir.appendingPathComponent("Wimm_2026-10-13_01-08-40_BD002026.m4a")
        image = dir.appendingPathComponent("Wimm_2026-10-13_02-00-00_ABCDEF12.jpg")
        try Data([0, 1, 2]).write(to: audio)
        try Data([0xFF, 0xD8]).write(to: image)
        try writeSidecar(for: audio, [
            "transcription": [
                "transcript": "Да. Да. Да.",
                "provider": "gemini", "model": "gemini-2.5-flash",
                "startedAt": "2026-09-20T10:00:00Z", "speechStatus": "speech",
                "previousRuns": [["transcript": "Transcription failed (network)", "replacedAt": "2026-09-19T10:00:00Z"],
                                 ["transcript": "Самый первый текст", "provider": "gemini",
                                  "model": "gemini-flash-lite-latest", "replacedAt": "2026-09-20T10:00:00Z"]],
            ],
            "noteCard": ["title": "Да", "summary": "Повтор", "processed_at": "2026-09-20T10:01:00Z"],
        ])
        try writeSidecar(for: image, ["ocr": ["text": "Счёт 42 EUR"]])
        workerStarts = Counter()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeSidecar(for media: URL, _ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: FileStore.metadataURL(forRecordingURL: media))
    }

    private func sidecarSHA(_ media: URL) throws -> String {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: media))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var notes: [RecallNote] {
        [
            RecallNote(id: "AAAA1111-0000-0000-0000-000000000001", date: Self.base.addingTimeInterval(-86_400),
                       kind: "audio", title: "Да", summary: "Повтор", text: "Да. Да. Да.",
                       filePath: audio.path, duration: 113, speech: "speech", chars: 11,
                       updated: Self.base.addingTimeInterval(-3600)),
            RecallNote(id: "BBBB2222-0000-0000-0000-000000000002", date: Self.base.addingTimeInterval(-7200),
                       kind: "image", title: nil, summary: nil, text: "",
                       filePath: image.path, updated: Self.base.addingTimeInterval(-1800)),
        ]
    }

    private func server(isPrivate: Bool = false) -> MCPRecallServer {
        let state = dir.appendingPathComponent("AgentState")
        let counter = workerStarts!
        let notes = self.notes
        return MCPRecallServer(
            now: { Self.base }, isPrivate: { isPrivate },
            marks: AgentMarkStore(directory: state),
            queue: RetranscriptionQueue(directory: state),
            retranscriptionModel: { "gemini-test-model" },
            startRetranscriptionWorker: { counter.bump() },
            library: { RecallLibrary(notes) })
    }

    private func tool(_ name: String, _ args: String, isPrivate: Bool = false) async throws -> (String, Bool) {
        let raw = await server(isPrivate: isPrivate).handle(
            line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (content.first?["text"] as? String ?? "", result["isError"] as? Bool ?? false)
    }

    func testToolsAreAdvertised() async throws {
        let raw = await server().handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
        let names = ((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, [
            "search_notes", "recent_notes", "changed_notes", "get_note", "get_note_image", "request_retranscription",
            "retranscription_queue", "mark_notes", "marked_notes", "set_pass_boundary", "create_note",
        ])
    }

    /// Agents keep registries by file name; the id is a hash of the path.
    func testGetNoteResolvesFileNamesAndShowsEarlierTranscripts() async throws {
        for ref in ["Wimm_2026-10-13_01-08-40_BD002026.m4a", "Wimm_2026-10-13_01-08-40_BD002026.meta.json",
                    "Wimm_2026-10-13_01-08-40_BD002026", "../recordings/Wimm_2026-10-13_01-08-40_BD002026.meta.json"] {
            let (text, isError) = try await tool("get_note", #"{"id":"\#(ref)"}"#)
            XCTAssertFalse(isError, ref)
            XCTAssertTrue(text.contains("id: AAAA1111"), ref)
        }
        let (text, _) = try await tool("get_note", #"{"id":"AAAA"}"#)
        XCTAssertTrue(text.contains("earlier transcript 1 (gemini/gemini-flash-lite-latest"))
        XCTAssertTrue(text.contains("Самый первый текст"))
        // A failure placeholder a run replaced is not text.
        XCTAssertFalse(text.contains("Transcription failed"))
        let (missing, isError) = try await tool("get_note", #"{"id":"Wimm_2099-01-01_00-00-00_NOPE.m4a"}"#)
        XCTAssertTrue(isError)
        XCTAssertTrue(missing.contains("No single note"))
    }

    /// A mark lives outside the note: the sidecar hash does not move, and a
    /// sync-only write later does not count as a change of content.
    func testMarksNeverTouchTheNoteAndSeeThroughSyncWrites() async throws {
        let before = try sidecarSHA(audio)
        let (reply, isError) = try await tool("mark_notes",
            #"{"marks":[{"id":"Wimm_2026-10-13_01-08-40_BD002026.m4a","status":"applied","source":"S1157"},{"id":"nope","status":"noise"}]}"#)
        XCTAssertFalse(isError)
        XCTAssertTrue(reply.contains("1 of 2 mark(s) stored"))
        XCTAssertTrue(reply.contains("nope: no single note matches"))
        XCTAssertEqual(try sidecarSHA(audio), before)

        var (note, _) = try await tool("get_note", #"{"id":"AAAA"}"#)
        XCTAssertTrue(note.contains("mark: applied · source S1157 · marked 2026-09-21"))
        XCTAssertTrue(note.contains("since mark: unchanged"))

        // A sync bumps the sidecar: still unchanged, and hidden on request.
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: audio))) as? [String: Any])
        dict["syncUpdatedAt"] = "2026-09-21T00:00:00.000Z"
        try writeSidecar(for: audio, dict)
        (note, _) = try await tool("get_note", #"{"id":"AAAA"}"#)
        XCTAssertTrue(note.contains("since mark: unchanged"))
        var (changed, _) = try await tool("changed_notes", #"{"since":"2026-09-01","skip_unchanged_marked":true}"#)
        XCTAssertFalse(changed.contains("[AAAA1111"))
        XCTAssertTrue(changed.contains("[BBBB2222"))

        // A new transcript is a change of text and comes back.
        var transcription = try XCTUnwrap(dict["transcription"] as? [String: Any])
        transcription["transcript"] = "Настоящий текст записи"
        dict["transcription"] = transcription
        try writeSidecar(for: audio, dict)
        (changed, _) = try await tool("changed_notes", #"{"since":"2026-09-01","skip_unchanged_marked":true}"#)
        XCTAssertTrue(changed.contains("[AAAA1111"))
        XCTAssertTrue(changed.contains("since mark: text changed"))

        let (listed, _) = try await tool("marked_notes", #"{"changed_since_mark":true}"#)
        XCTAssertTrue(listed.contains("1 marked note(s)"))
        XCTAssertTrue(listed.contains("source S1157"))

        let (cleared, _) = try await tool("mark_notes", #"{"marks":[{"id":"AAAA","status":"clear"}]}"#)
        XCTAssertTrue(cleared.contains("mark cleared"))
        let (none, _) = try await tool("marked_notes", "{}")
        XCTAssertEqual(none, "No marked notes match.")
    }

    func testMarkRejectsUnknownStatus() async throws {
        let (reply, _) = try await tool("mark_notes", #"{"marks":[{"id":"AAAA","status":"done"}]}"#)
        XCTAssertTrue(reply.contains("0 of 1 mark(s)"))
        XCTAssertTrue(reply.contains("status must be applied, pending, noise, failed or clear"))
    }

    func testPassBoundaryFeedsChangedNotes() async throws {
        let (missing, isError) = try await tool("changed_notes", #"{"since":"last_pass"}"#)
        XCTAssertTrue(isError)
        XCTAssertTrue(missing.contains("No pass boundary"))

        // Between the two notes' change times: only the image changed after it.
        let (stored, _) = try await tool("set_pass_boundary", #"{"as_of":"2026-09-21T15:30:00+02:00","comment":"pass 12"}"#)
        XCTAssertTrue(stored.hasPrefix("Pass boundary stored"))
        let (changed, _) = try await tool("changed_notes", #"{"since":"last_pass"}"#)
        XCTAssertTrue(changed.contains("total: 1"))
        XCTAssertTrue(changed.contains("[BBBB2222"))
        XCTAssertTrue(changed.contains("last_pass: "))
        XCTAssertTrue(changed.contains("pass 12"))
        XCTAssertTrue(changed.contains("changes: metadata"))
    }

    func testRetranscriptionRequestsQueueAudioOnlyAndOnce() async throws {
        let (reply, isError) = try await tool("request_retranscription",
            #"{"ids":["Wimm_2026-10-13_01-08-40_BD002026","BBBB","nope"],"reason":"looped"}"#)
        XCTAssertFalse(isError)
        XCTAssertTrue(reply.hasPrefix("1 of 3 queued with gemini-test-model"))
        XCTAssertTrue(reply.contains("BBBB: not audio (image)"))
        XCTAssertTrue(reply.contains("nope: no single note matches"))
        XCTAssertEqual(workerStarts.count, 1)

        let (again, _) = try await tool("request_retranscription", #"{"ids":["AAAA"],"model":"parakeet:ultra"}"#)
        XCTAssertTrue(again.hasPrefix("0 of 1 queued"))
        XCTAssertTrue(again.contains("already queued"))
        XCTAssertEqual(workerStarts.count, 1)

        let queue = RetranscriptionQueue(directory: dir.appendingPathComponent("AgentState"))
        XCTAssertEqual(queue.entries().map(\.state), [.queued])
        XCTAssertEqual(queue.entries().first?.reason, "looped")

        let (note, _) = try await tool("get_note", #"{"id":"AAAA"}"#)
        XCTAssertTrue(note.contains("retranscription: queued 2026-09-21"))
        let (listed, _) = try await tool("retranscription_queue", #"{"state":"queued"}"#)
        XCTAssertTrue(listed.contains("1 request(s) in state queued"))
    }

    /// An Evernote note is text with its recording as an attachment: each
    /// audio attachment is queued on its own, pointing back at the note, and
    /// the note's get_note shows the request.
    func testRetranscriptionOfATextNoteQueuesItsAudioAttachments() async throws {
        let folder = dir.appendingPathComponent("Attachments/Evernote/A86", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = dir.appendingPathComponent("Wimm_2019-04-09_19-04-15_a861814c.txt")
        let first = folder.appendingPathComponent("Evernote_20190409_19:04:22.m4a")
        let second = folder.appendingPathComponent("Evernote_20190409_19:30:00.m4a")
        for file in [text, first, second] { try Data([1]).write(to: file) }
        let firstID = UUID(), secondID = UUID()
        try writeSidecar(for: text, ["importSource": "Evernote", "attachments": [
            ["id": firstID.uuidString, "type": "audio", "url": first.absoluteString, "extractedText": "старый"],
            ["id": UUID().uuidString, "type": "image", "url": folder.appendingPathComponent("a.jpg").absoluteString],
            ["id": secondID.uuidString, "type": "audio", "url": second.absoluteString],
        ]])
        let evernote = RecallNote(id: "CCCC3333-0000-0000-0000-000000000003", date: Self.base.addingTimeInterval(-9000),
                                  kind: "text", title: "Бабушка", summary: nil, text: "# Бабушка",
                                  filePath: text.path)
        let state = dir.appendingPathComponent("AgentState")
        let notes = self.notes + [evernote]
        let server = MCPRecallServer(
            now: { Self.base }, isPrivate: { false },
            marks: AgentMarkStore(directory: state), queue: RetranscriptionQueue(directory: state),
            retranscriptionModel: { "gemini-test-model" }, startRetranscriptionWorker: {},
            library: { RecallLibrary(notes) })
        func call(_ name: String, _ args: String) async throws -> String {
            let raw = await server.handle(
                line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
            let content = try XCTUnwrap((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])
            return content.first?["text"] as? String ?? ""
        }

        let reply = try await call("request_retranscription", #"{"ids":["CCCC"]}"#)
        XCTAssertTrue(reply.hasPrefix("2 of 2 queued"), reply)
        XCTAssertTrue(reply.contains("Evernote_20190409_19:04:22.m4a (attachment): queued"))
        let entries = RetranscriptionQueue(directory: state).entries()
        XCTAssertEqual(entries.map(\.file), [first.path, second.path])
        XCTAssertEqual(Set(entries.compactMap(\.parentFile)), [text.path])
        XCTAssertEqual(entries.map(\.attachmentID), [firstID.uuidString, secondID.uuidString])
        XCTAssertEqual(entries.map(\.analyze), [false, true], "one analysis per note, after its last attachment")

        let note = try await call("get_note", #"{"id":"CCCC"}"#)
        XCTAssertTrue(note.contains("retranscription: queued 2026-09-21"), note)

        // A text note without audio is still refused.
        try writeSidecar(for: text, ["importSource": "Evernote"])
        let none = try await call("request_retranscription", #"{"ids":["CCCC"]}"#)
        XCTAssertTrue(none.contains("not audio (text) and no audio attachments"), none)
    }

    /// Private mode: no audio may leave the Mac, so only on-device Parakeet is
    /// queued; the reading tools stay closed.
    func testPrivateModeQueuesOnlyOnDeviceRetranscription() async throws {
        let (cloud, cloudError) = try await tool("request_retranscription", #"{"ids":["AAAA"]}"#, isPrivate: true)
        XCTAssertTrue(cloudError)
        XCTAssertTrue(cloud.contains("gemini-test-model would send the audio to the cloud"))
        let queue = RetranscriptionQueue(directory: dir.appendingPathComponent("AgentState"))
        XCTAssertTrue(queue.entries().isEmpty)
        XCTAssertEqual(workerStarts.count, 0)

        let (local, localError) = try await tool("request_retranscription",
            #"{"ids":["AAAA"],"model":"parakeet:ultra"}"#, isPrivate: true)
        XCTAssertFalse(localError)
        XCTAssertTrue(local.hasPrefix("1 of 1 queued with parakeet:ultra"))
        XCTAssertEqual(queue.entries().map(\.model), ["parakeet:ultra"])
        XCTAssertEqual(workerStarts.count, 1)

        let (listed, listError) = try await tool("retranscription_queue", "{}", isPrivate: true)
        XCTAssertFalse(listError)
        XCTAssertTrue(listed.contains("1 request(s)"))
        let (_, readError) = try await tool("get_note", #"{"id":"AAAA"}"#, isPrivate: true)
        XCTAssertTrue(readError)
    }

    func testQueueRequeuesWorkOfDeadWorkersAndRecordsOutcome() throws {
        let queue = RetranscriptionQueue(directory: dir.appendingPathComponent("AgentState"))
        let entry = RetranscriptionQueue.Entry(file: audio.path, noteId: "AAAA", model: "m", analyze: true,
                                               reason: nil, requestedAt: Self.base)
        _ = try queue.enqueue([entry])
        let claimed = try XCTUnwrap(try queue.claimNext(pid: 111, isAlive: { _ in true }))
        XCTAssertEqual(claimed.workerPID, 111)
        XCTAssertNil(try queue.claimNext(pid: 222, isAlive: { _ in true }))
        // Worker 111 died: the entry goes back to the queue and 222 takes it.
        let retaken = try XCTUnwrap(try queue.claimNext(pid: 222, isAlive: { _ in false }))
        XCTAssertEqual(retaken.workerPID, 222)
        try queue.finish(retaken, failed: false, outcome: "speech: 10 chars")
        XCTAssertEqual(queue.latest(forFile: audio.path)?.state, .done)
        XCTAssertEqual(queue.latest(forFile: audio.path)?.outcome, "speech: 10 chars")
        XCTAssertFalse(queue.hasQueued)
        // A finished request does not block a new one.
        XCTAssertEqual(try queue.enqueue([entry]), [.queued])
    }

    func testChangeKindsComeFromPipelineTimestamps() {
        let since = ISO8601.date(from: "2026-09-21T00:00:00Z")!
        let meta = RecallSidecar([
            "transcription": ["startedAt": "2026-09-21T08:00:00Z", "transcript": "x"],
            "noteCard": ["processed_at": "2026-09-20T08:00:00Z", "refined_edited_at": "2026-09-22T08:00:00Z"],
            "syncUpdatedAt": "2026-09-21T09:00:00.123Z",
        ])
        XCTAssertEqual(NoteChangeKind.kinds(meta, since: since), [.transcript, .edited, .sync])
        XCTAssertEqual(NoteChangeKind.kinds(RecallSidecar([:]), since: since), [.metadata])
    }

    /// A model-written refined text is analysis; once a person edits it, it is text.
    func testFingerprintSeparatesTextFromAnalysis() {
        let model = NoteFingerprint.make(RecallSidecar(["noteCard": ["refined_text": "A", "title": "T"]]), typed: nil)
        let rewritten = NoteFingerprint.make(RecallSidecar(["noteCard": ["refined_text": "B", "title": "T"]]), typed: nil)
        XCTAssertEqual(model.text, rewritten.text)
        XCTAssertNotEqual(model.analysis, rewritten.analysis)
        let edited = NoteFingerprint.make(
            RecallSidecar(["noteCard": ["refined_text": "B", "title": "T", "refined_edited_at": "2026-09-21T00:00:00Z"]]),
            typed: nil)
        XCTAssertNotEqual(edited.text, model.text)
    }

    /// A re-run that only moves punctuation or case keeps the wording; a new word does not.
    func testWordingIgnoresPunctuationAndCaseOnly() {
        let before = NoteFingerprint.make(RecallSidecar([:]), typed: "Привет, мир. Купить хлеб!")
        let comma = NoteFingerprint.make(RecallSidecar([:]), typed: "привет мир — купить хлеб")
        let word = NoteFingerprint.make(RecallSidecar([:]), typed: "Привет, мир. Купить молоко!")
        XCTAssertNotEqual(before.text, comma.text)
        XCTAssertEqual(before.wording, comma.wording)
        XCTAssertNotEqual(before.wording, word.wording)
        let mark = AgentMarkStore.Mark(status: .noise, source: "S1", markedAt: Date(), noteId: "n", text: before.text,
                                       analysis: before.analysis, wording: before.wording)
        XCTAssertEqual(MCPRecallServer.sinceMark(mark, comma), "punctuation changed")
        XCTAssertEqual(MCPRecallServer.sinceMark(mark, word), "text changed")
        var old = mark; old.wording = nil
        XCTAssertFalse(NoteFingerprint.sameWording(old, comma), "marks without wording keep the old behavior")
    }
}
