import Foundation
import XCTest
@testable import WimmInfrastructure

@MainActor
final class MyDocumentTests: XCTestCase {
    func testAmbiguousWriteReconcilesMarkerWithoutAnotherPost() async throws {
        let server = DocumentServer()
        let client = GoogleDocumentClient(send: { try await server.send($0) })
        do {
            try await client.append(documentID: "abc", text: "New entry", marker: "[WIMM: receipt]", accessToken: "test")
            XCTFail("First response should be lost")
        } catch { XCTAssertTrue(error is URLError) }
        try await client.append(documentID: "abc", text: "New entry", marker: "[WIMM: receipt]", accessToken: "test")
        let requests = await server.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        let body = try XCTUnwrap(requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["writeControl"] as? [String: String])?["requiredRevisionId"], "revision-1")
        let inserts = try XCTUnwrap(json["requests"] as? [[String: [String: Any]]])
        XCTAssertEqual((inserts[0]["insertText"]?["endOfSegmentLocation"] as? [String: String])?["tabId"], "first-tab")
    }

    func testConcurrentEditIsRereadBeforeRetry() async throws {
        let server = DocumentServer(conflict: true)
        let client = GoogleDocumentClient(send: { try await server.send($0) })
        do {
            try await client.append(documentID: "abc", text: "Entry", marker: "[WIMM: receipt]", accessToken: "test")
            XCTFail("Concurrent edit must reject append")
        } catch MyDocumentError.requestFailed(let code) { XCTAssertEqual(code, 400) }
        try await client.append(documentID: "abc", text: "Entry", marker: "[WIMM: receipt]", accessToken: "test")
        let requests = await server.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET", "POST"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[3].httpBody)) as? [String: Any])
        XCTAssertEqual((json["writeControl"] as? [String: String])?["requiredRevisionId"], "revision-2")
    }
    func testOnlyGoogleDocumentLinksAreAccepted() throws {
        XCTAssertEqual(try GoogleDocumentClient.documentID(from: "https://docs.google.com/document/d/abc_123-X/edit?tab=t.0"), "abc_123-X")
        for value in ["https://docs.google.com.evil.test/document/d/abc/edit", "http://docs.google.com/document/d/abc/edit",
                      "https://docs.google.com/spreadsheets/d/abc/edit", "https://docs.google.com/document/d/", "abc"] {
            XCTAssertThrowsError(try GoogleDocumentClient.documentID(from: value))
        }
    }

    func testQueueAndGeneratedReceiptSurviveRestartWithoutDuplicateSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json")
        let note = UUID()
        var state = MyDocumentState()
        state.enqueue(MyDocumentEntry(noteID: note, title: "Title", source: "note.txt", date: Date(), text: "Original"))
        state.entries[0].generatedText = "Prepared entry"
        state.awaitingNoteIDs.insert(UUID())
        let marker = state.entries[0].marker
        try state.save(to: url)
        var restored = try MyDocumentState.load(from: url)
        restored.enqueue(MyDocumentEntry(noteID: note, title: "Changed", source: "note.txt", date: Date(), text: "Changed original"))
        XCTAssertEqual(restored.entries.count, 1)
        XCTAssertEqual(restored.entries[0].generatedText, "Prepared entry")
        XCTAssertEqual(restored.entries[0].marker, marker)
        XCTAssertEqual(restored.awaitingNoteIDs, state.awaitingNoteIDs)
    }

    func testCorruptStateIsNotSilentlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("broken".utf8).write(to: url)
        XCTAssertThrowsError(try MyDocumentState.load(from: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "broken")
    }
}

private actor DocumentServer {
    var requests: [URLRequest] = []
    private var revision = 1
    private var text = "User edits remain here."
    private var conflict: Bool
    init(conflict: Bool = false) { self.conflict = conflict }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        let url = request.url!
        if request.httpMethod == "GET" {
            let doc: [String: Any] = ["revisionId": "revision-\(revision)", "tabs": [
                ["tabProperties": ["tabId": "first-tab"], "documentTab": ["body": ["content": []]]],
                ["tabProperties": ["tabId": "second-tab"], "documentTab": ["body": ["content": [
                    ["paragraph": ["elements": [["textRun": ["content": text]]]]]
                ]]]]
            ]]
            return (try JSONSerialization.data(withJSONObject: doc), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        revision += 1
        if conflict {
            conflict = false
            return (Data(), HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!)
        }
        text += "[WIMM: receipt]"
        // Lost response after the server committed the append.
        if requests.count == 2 { throw URLError(.networkConnectionLost) }
        return (Data("{}".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
