import Foundation
import XCTest
@testable import WimmSecretary

/// Opt-in export of the real packet selector's baseline; never reads the personal library.
final class SecretaryDecisionsRoutingTests: XCTestCase {
    func testExportSyntheticBaseline() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["WIMM_ROUTING_FIXTURE"], let output = env["WIMM_ROUTING_BASELINE"] else {
            throw XCTSkip("Opt-in Decisions routing experiment")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: input))
        var fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = try XCTUnwrap(fixture["sections"] as? [[String: String]])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        let limit = try XCTUnwrap(fixture["budget_bytes"] as? Int)
        // Eight short orientation blocks are compulsory in the production selector.
        let intro = (1...8).map { "Ориентир \($0)." }.joined(separator: "\n\n") + "\n\n"
        let document = intro + sections.map { "### \($0["title"]!)\n\n\($0["text"]!)\n\n" }.joined()
        let blocks = SecretaryPacket.blocks(document)
        let common = Array(blocks.prefix(8))
        var bodyIDs: [String: String] = [:], sectionBlocks: [String: [String]] = [:]
        for section in sections {
            let members = blocks.filter { $0.section == "### " + section["title"]! }
            XCTAssertEqual(members.count, 2)
            bodyIDs[section["id"]!] = members.last!.id
            sectionBlocks[section["id"]!] = members.map(\.id)
        }
        var results: [[String: Any]] = []
        for item in cases {
            let text = item["text"] as! String
            let start = DispatchTime.now().uptimeNanoseconds
            // This is the current packet path, not the optional editor-bundle selector.
            let chosen = SecretaryPacket.select(blocks: blocks, sourceIDs: [], terms: SecretaryPacket.terms(text),
                limit: limit, sourceTerms: [SecretaryPacket.evidenceTerms(text)])
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let selected = Set(chosen.map(\.id))
            XCTAssertLessThanOrEqual(chosen.reduce(0) { $0 + $1.text.utf8.count }, limit)
            XCTAssertTrue(Set(common.map(\.id)).isSubset(of: selected))
            results.append(["id": item["id"]!, "selected": sections.compactMap { s in
                selected.contains(bodyIDs[s["id"]!]!) ? s["id"] : nil
            }, "blocks": chosen.map(\.id), "bytes": chosen.reduce(0) { $0 + $1.text.utf8.count }, "wall_ms": elapsed])
        }
        fixture["baseline"] = results
        fixture["blocks"] = blocks.map { ["id": $0.id, "text": $0.text] }
        fixture["common_blocks"] = common.map(\.id)
        fixture["section_blocks"] = sectionBlocks
        fixture["fixture_sha256_note"] = "Hash is added by Python runner; labels are frozen in fixture before API calls."
        try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    func testExportRealBaseline() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["WIMM_REAL_ROUTING_DATASET"], let output = env["WIMM_REAL_ROUTING_BASELINE"] else {
            throw XCTSkip("Opt-in real Decisions routing experiment")
        }
        var dataset = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: input))) as? [String: Any])
        var documents = dataset["documents"] as! [String: [String: Any]]
        let cases = dataset["cases"] as! [[String: Any]]
        let limit = dataset["budget_bytes"] as! Int
        var results: [[String: Any]] = []
        for item in cases {
            let run = item["run"] as! String, text = item["text"] as! String
            let blocks = SecretaryPacket.blocks(documents[run]!["text"] as! String)
            let ids = [item["source"] as! String]
            let start = DispatchTime.now().uptimeNanoseconds
            let chosen = SecretaryPacket.select(blocks: blocks, sourceIDs: ids, terms: SecretaryPacket.terms(text),
                limit: limit, sourceTerms: [SecretaryPacket.evidenceTerms(text)])
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let pinned = SecretaryPacket.select(blocks: blocks, sourceIDs: ids, terms: [], limit: limit)
            XCTAssertLessThanOrEqual(chosen.reduce(0) { $0 + $1.text.utf8.count }, limit)
            results.append(["id": item["id"]!, "blocks": chosen.map(\.id), "pinned": pinned.map(\.id),
                "bytes": chosen.reduce(0) { $0 + $1.text.utf8.count }, "wall_ms": elapsed])
            documents[run]!["blocks"] = blocks.map { ["id": $0.id, "text": $0.text] }
        }
        dataset["documents"] = documents
        dataset["baseline"] = results
        try JSONSerialization.data(withJSONObject: dataset, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }

    func testMaterializeEditorialReplay() throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["WIMM_EDITORIAL_REPLAY"] else { throw XCTSkip("Opt-in editorial replay") }
        let directory = URL(fileURLWithPath: folder)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("secretary"), withIntermediateDirectories: true)
        let workspace = try XCTUnwrap(SecretaryWorkspace(document: root.appendingPathComponent("docs/me.md")))
        let task = SecretaryTask(id: "editorial-replay", kind: .pass, workspace: workspace, threads: [],
            wimmCLI: "/usr/bin/true", createdAt: Date(), packetMode: true)
        let datasetURL = URL(fileURLWithPath: env["WIMM_REAL_ROUTING_BASELINE"]!)
        let dataset = try JSONSerialization.jsonObject(with: Data(contentsOf: datasetURL)) as! [String: Any]
        let documents = dataset["documents"] as! [String: [String: Any]]
        let cases = dataset["cases"] as! [[String: Any]]
        let plan = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("plan.json"))) as! [String: Any]
        var rows: [[String: Any]] = []
        for result in plan["results"] as! [[String: Any]] where result["accepted"] as! Bool {
            let tag = result["tag"] as! String, cid = result["case"] as! String
            let item = cases.first { $0["id"] as? String == cid }!
            let doc = documents[item["run"] as! String]!["text"] as! String
            let blocks = SecretaryPacket.blocks(doc)
            let reply = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(tag + "-reply.json"))) as! [String: Any]
            let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent(tag + "-final-input.json"))) as! [String: Any]
            let allowed = Set((payload["document_blocks"] as! [[String: Any]]).map { $0["id"] as! String })
            let packet = SecretaryPacket(task: task, documentData: Data(doc.utf8), registryData: Data(), queueData: Data(),
                blocks: blocks, selected: [], receipts: [], projectedSourceIDs: [], newSources: [], fullSourcesByID: [:], payload: payload, system: "")
            let operations = reply["edits"] as! [[String: Any]]
            let literal = operations.map { op -> SecretaryPacket.Edit in
                SecretaryPacket.Edit(block: op["block"] as! String, text: op["text"] as! String,
                    operation: op["operation"] as? String, match: op["match"] as? String)
            }
            let edits = try packet.materializedEdits(literal, allowed: allowed)
            for edit in edits {
                let index = blocks.firstIndex { $0.id == edit.block }!
                let boundaryAfter = index == blocks.count - 1 || edit.text.hasSuffix("\n\n")
                var text = blocks.map(\.text);text[index] = edit.text
                rows.append(["tag": tag, "block": edit.block, "boundary_after_preserved": boundaryAfter,
                    "before": blocks[index].text, "after": edit.text,
                    "next": index + 1 < blocks.count ? blocks[index + 1].text : "",
                    "heading_count_before": blocks.filter { SecretaryPacket.heading($0.text) != nil }.count,
                    "heading_count_after": SecretaryPacket.blocks(text.joined()).filter { SecretaryPacket.heading($0.text) != nil }.count])
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("swift-materialization.json"), options: .atomic)
    }

}
