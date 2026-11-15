import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryDocumentToolsTests: XCTestCase {
    private var dir: URL!
    private var file: URL!

    private let document = """
    # Личный документ

    Вступление.

    ## Работа

    Сезон на Рюгене закончился 23 октября. [S1]

    ### Поиск работы

    Резюме отправлено в июле.

    ## Семья

    Варвара любит балет.

    [S1]: recordings/a.m4a
    """

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("doc-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("doc.md")
        try Data(document.utf8).write(to: file)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func server(isPrivate: Bool = false, allowed: Set<String>? = nil, document: URL?? = nil) -> MCPRecallServer {
        let url = document ?? file
        return MCPRecallServer(isPrivate: { isPrivate }, allowedTools: allowed,
                               extraTools: SecretaryDocumentTools.mcpTools(document: { url }),
                               extraInstructions: SecretaryDocumentTools.instructions,
                               library: { RecallLibrary([]) })
    }

    private func call(_ server: MCPRecallServer, _ name: String, _ args: String) async throws -> (json: [String: Any], text: String, isError: Bool) {
        let raw = await server.handle(
            line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(args)}}"#)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (json, text, result["isError"] as? Bool ?? false)
    }

    private func toolNames(_ server: MCPRecallServer) async throws -> [String] {
        let raw = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(raw).utf8)) as? [String: Any])
        let tools = try XCTUnwrap((reply["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        return tools.compactMap { $0["name"] as? String }
    }

    func testToolsAreListedAndFollowTheSessionFilter() async throws {
        let names = try await toolNames(server())
        for name in ["document_outline", "document_section", "document_find", "document_blocks"] {
            XCTAssertTrue(names.contains(name), name)
        }
        let limited = try await toolNames(server(allowed: ["search_notes"]))
        XCTAssertFalse(limited.contains("document_outline"))
        let refused = try await call(server(allowed: ["search_notes"]), "document_outline", "{}")
        XCTAssertTrue(refused.isError)
    }

    func testPrivateModeRefusesDocumentReads() async throws {
        let read = try await call(server(isPrivate: true), "document_outline", "{}")
        XCTAssertTrue(read.isError)
        XCTAssertFalse(read.text.contains("Работа"))
    }

    func testOutlineThenSeveralSectionsInOneCall() async throws {
        let server = server()
        let outline = try await call(server, "document_outline", #"{"max_depth":2}"#)
        XCTAssertFalse(outline.isError, outline.text)
        let headings = try XCTUnwrap((outline.json["result"] as? [String: Any])?["headings"] as? [[String: Any]])
        XCTAssertEqual(headings.compactMap { $0["title"] as? String }, ["# Личный документ", "## Работа", "## Семья"])
        let version = try XCTUnwrap(outline.json["version"] as? String)

        let read = try await call(server, "document_section", #"{"sections":["Работа","Семья"],"version":"\#(version)"}"#)
        XCTAssertFalse(read.isError, read.text)
        let sections = try XCTUnwrap((read.json["result"] as? [String: Any])?["sections"] as? [[String: Any]])
        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(read.text.contains("Резюме отправлено"))
        XCTAssertTrue(read.text.contains("Варвара"))
        XCTAssertFalse(read.text.contains("recordings/a.m4a"), "citation definitions are not evidence blocks")
        XCTAssertEqual(read.json["version"] as? String, version)
    }

    func testSectionsShareTheByteBudget() async throws {
        let read = try await call(server(), "document_section", #"{"sections":["Работа","Семья"],"limit_bytes":10}"#)
        let result = try XCTUnwrap(read.json["result"] as? [String: Any])
        XCTAssertEqual(result["not_read"] as? [String], ["Семья"])
        let first = try XCTUnwrap(((result["sections"] as? [[String: Any]])?.first?["read"]) as? [String: Any])
        XCTAssertEqual(first["status"] as? String, "partial")
        XCTAssertNotNil(first["next_offset"])
    }

    func testFindAnswersSeveralQueriesAndMatchesTheReader() async throws {
        let read = try await call(server(), "document_find", #"{"queries":["балет","резюме","небывальщина"]}"#)
        XCTAssertFalse(read.isError, read.text)
        let result = try XCTUnwrap(read.json["result"] as? [String: Any])
        let reports = try XCTUnwrap(result["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.compactMap { $0["status"] as? String }, ["matched", "matched", "not_found"])
        XCTAssertTrue(read.text.contains("Варвара любит балет"))
        XCTAssertTrue(read.text.contains("Резюме отправлено"))

        let snapshot = SecretaryDocumentReader.Snapshot(document: document)
        XCTAssertEqual(snapshot.find(queries: ["балет"]).blocks,
                       SecretaryDocumentReader.find(document: document, query: "балет").blocks)
    }

    func testBlocksReportMissingIDs() async throws {
        let read = try await call(server(), "document_blocks", #"{"ids":["b1","b999"]}"#)
        let result = try XCTUnwrap(read.json["result"] as? [String: Any])
        XCTAssertEqual((result["blocks"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(result["missing"] as? [String], ["b999"])
    }

    func testCacheParsesOncePerFileVersionAndAStaleVersionIsRefused() async throws {
        let url = try XCTUnwrap(file)
        let cache = SecretaryDocumentTools.Cache(document: { url })
        let first = try await cache.load()
        _ = try await cache.load()
        var parses = await cache.parses
        XCTAssertEqual(parses, 1, "an unchanged file is not parsed again")

        try Data((document + "\n\n## Новое\n\nТекст.\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let second = try await cache.load()
        parses = await cache.parses
        XCTAssertEqual(parses, 2)
        XCTAssertNotEqual(first.version, second.version)
        XCTAssertTrue(second.snapshot.outline().contains { $0.title == "## Новое" })

        let stale = try await call(server(), "document_outline", #"{"version":"\#(first.version)"}"#)
        XCTAssertTrue(stale.isError)
        XCTAssertTrue(stale.text.contains("changed"))
    }

    func testNoConfiguredDocumentIsAnError() async throws {
        let read = try await call(server(document: .some(nil)), "document_outline", "{}")
        XCTAssertTrue(read.isError)
        XCTAssertTrue(read.text.contains("WIMM_DOCUMENT"))
    }
}
