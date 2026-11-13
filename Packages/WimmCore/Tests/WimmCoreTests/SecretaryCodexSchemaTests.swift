import Foundation
import XCTest
@testable import WimmSecretary

final class SecretaryCodexSchemaTests: XCTestCase {
    func testPacketCLIOptsIntoStrictSchemaAndNormalAgentStaysUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var request = SecretaryExecutionRequest(workspaceRoot: root, runDirectory: root, prompt: "fixture", kind: .pass,
            wimmCLI: "/unused", budgetUSD: 0, model: "fixture", timeout: 1)
        let executor = CodexExecutor(binary: URL(fileURLWithPath: "/unused-codex"))
        XCTAssertFalse(executor.arguments(for: request, lastMessage: root.appendingPathComponent("last.txt")).contains("--output-schema"))
        request.systemPrompt = "Fixture policy"
        request.outputJSONSchema = try SecretaryPacket.codexJSONSchema()
        let args = executor.arguments(for: request, lastMessage: root.appendingPathComponent("last.txt"))
        let index = try XCTUnwrap(args.firstIndex(of: "--output-schema"))
        XCTAssertEqual(args[index + 1], root.appendingPathComponent("output-schema.json").path)
        XCTAssertTrue(args.contains("read-only"))
        func check(_ node: [String: Any]) {
            if node["type"] as? String == "object" {
                let props = node["properties"] as! [String: Any]
                XCTAssertEqual(Set(node["required"] as! [String]), Set(props.keys))
                XCTAssertEqual(node["additionalProperties"] as? Bool, false)
                for child in props.values { check(child as! [String: Any]) }
            }
            if let items = node["items"] as? [String: Any] { check(items) }
            if let variants = node["anyOf"] as? [[String: Any]] { for variant in variants { check(variant) } }
        }
        check(try JSONSerialization.jsonObject(with: request.outputJSONSchema!) as! [String: Any])
    }

    func testEachOperationAllowsOnlyItsOwnTargetAndMatchFields() throws {
        let schema = try JSONSerialization.jsonObject(with: SecretaryPacket.codexJSONSchema()) as! [String: Any]
        let props = schema["properties"] as! [String: Any]
        let edits = props["edits"] as! [String: Any]
        let variants = (edits["items"] as! [String: Any])["anyOf"] as! [[String: Any]]
        XCTAssertEqual(variants.count, 4)
        for variant in variants {
            let fields = variant["properties"] as! [String: Any]
            let operation = ((fields["operation"] as! [String: Any])["enum"] as! [String])[0]
            XCTAssertEqual((fields["match"] as! [String: Any])["type"] as? String, operation == "replace_text" ? "string" : "null")
            XCTAssertEqual((fields["section"] as! [String: Any])["type"] as? String, operation == "insert_under_heading" ? "string" : "null")
            XCTAssertEqual((fields["block"] as! [String: Any])["type"] as? String, operation == "insert_under_heading" ? "null" : "string")
        }
    }

    func testNullableTransportFieldsDecodeWithoutWeakeningNativeContract() throws {
        let body = #"{"summary":"fixture","edits":[{"operation":"insert_after","section":null,"block":"b1","match":null,"text":"Факт [S1].","sources":["S1"]}],"done_no_additions":[],"not_a_note":[],"unfinished":[],"questions":[]}"#
        _ = try JSONDecoder().decode(SecretaryPacket.EditsReply.self, from: Data(body.utf8))
        let exported = try JSONSerialization.jsonObject(with: Data(SecretaryPacketFiles.editsResponseSchema.utf8)) as! [String: Any]
        let props = exported["properties"] as! [String: Any]
        let items = (props["edits"] as! [String: Any])["items"] as! [String: Any]
        let fields = items["properties"] as! [String: Any]
        XCTAssertEqual((fields["section"] as! [String: Any])["type"] as? [String], ["string", "null"])
    }
}
