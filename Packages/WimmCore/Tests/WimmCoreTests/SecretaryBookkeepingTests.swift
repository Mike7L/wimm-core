import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryBookkeepingTests: XCTestCase {
    private var root: URL!
    private var store: AgentMarkStore!
    private var media: URL { root.appendingPathComponent("recordings/note.txt") }
    private var document: URL { root.appendingPathComponent("docs/me.md") }
    private var sidecar: URL { FileStore.metadataURL(forRecordingURL: media) }
    private var task: SecretaryTask {
        SecretaryTask(id: "test-run", kind: .pass, workspace: SecretaryWorkspace(document: document)!,
                      threads: [], wimmCLI: "/usr/bin/true", createdAt: Date())
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bookkeeping-\(UUID().uuidString)")
        for name in ["docs", "recordings", "secretary"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        store = AgentMarkStore(directory: root.appendingPathComponent("state"))
        try "current typed body".write(to: media, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: sidecar) { $0["transcription"] = ["transcript": "stored transcript"]; return true }
        try "# Document\n\nA fact [S1].\n\n[S1]: ../recordings/\(sidecar.lastPathComponent)\n".write(to: document, atomically: true, encoding: .utf8)
        try registry()
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func registry(status: String = "applied", extra: [[String: Any]] = []) throws {
        let sources: [[String: Any]] = [["source_id": "S1", "path": "../recordings/\(sidecar.lastPathComponent)", "status": status,
                                      "reason": "semantic decision", "merged_with": ["S9"]]] + extra
        var counts: [String: Int] = [:]
        for source in sources { counts[source["status"] as! String, default: 0] += 1 }
        let value: [String: Any] = ["sources": sources, "source_count": sources.count, "counts": counts]
        try JSONSerialization.data(withJSONObject: value).write(to: document.deletingPathExtension().appendingPathExtension("sources.json"))
    }

    @discardableResult private func read(isPrivate: Bool = false) async throws -> String {
        let note = RecallNote(id: "note-id", date: Date(), kind: "text", title: nil, summary: nil,
                              text: "stale cached body", filePath: media.path)
        let server = MCPRecallServer(isPrivate: { isPrivate }, marks: store,
                                     readLog: SecretaryReadReceipt.logURL(runID: task.id, store: store),
                                     library: { RecallLibrary([note]) })
        let response = await server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_note","arguments":{"id":"note-id"}}}"#)
        return try XCTUnwrap(response)
    }

    private func finish(_ ids: [String]?) async -> SecretaryBookkeepingReport {
        let result = SecretaryResult(reviewedSources: ids)
        let media = media
        return await SecretaryBookkeeping.finish(task: task, result: result, store: store, recordings: { [media] })
    }

    func testDescriptiveChecksDoNotDiscardReviewsOrClaimVerification() async throws {
        let result = try JSONDecoder().decode(SecretaryResult.self, from: Data(#"{"reviewed_sources":["S1"],"checks":["registry JSON written",{"name":"semantic check","ok":false}]}"#.utf8))
        XCTAssertEqual(result.reviewedSources, ["S1"])
        XCTAssertNil(result.checks?.first?.ok, "a descriptive string is not proof of a passed check")
        XCTAssertEqual(result.checks?.last?.ok, false, "structured failure remains a failure")
        let before = SecretarySnapshot.take(task.workspace)
        XCTAssertTrue(SecretaryVerification.findings(task: task, before: before, after: before, result: result, resultError: nil).contains {
            $0.contains("Agent check failed: semantic check")
        })
        let plain = try JSONDecoder().decode(SecretaryResult.self, from: Data(#"{"reviewed_sources":["S1"],"checks":["registry JSON written"]}"#.utf8))
        try await read()
        let media = media
        let report = await SecretaryBookkeeping.finish(task: task, result: plain, store: store, recordings: { [media] })
        XCTAssertEqual(report.stored, 1)
        XCTAssertEqual(report.findings, [])
    }

    func testSourcelessUserMarkIsNotARegistryFinding() async throws {
        try store.update(["user-held.txt": .init(status: .noise, source: nil, comment: "user decision",
                                                 markedAt: .distantPast, noteId: "held", text: "", analysis: "")])
        try await read()
        let report = await finish(["S1"])
        XCTAssertEqual(report.findings, [], "a mark set outside the registry is not secretary bookkeeping")
        try store.update(["stray.txt": .init(status: .noise, source: "S404", markedAt: .distantPast, noteId: "stray", text: "", analysis: "")])
        try await read()
        let again = await finish(["S1"])
        XCTAssertTrue(again.findings.contains("Wimm mark has no matching registry source."), "an unknown source id is still reported")
    }

    func testHostCopiesSemanticStatusAndReadsFreshTypedBody() async throws {
        try registry(status: "duplicate")
        let before = try Data(contentsOf: sidecar)
        let text = try await read()
        XCTAssertTrue(text.contains("current typed body"))
        XCTAssertFalse(text.contains("stale cached body"))
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 1)
        XCTAssertEqual(report.findings, [])
        let mark = try XCTUnwrap(store.mark(forFile: media.lastPathComponent))
        XCTAssertEqual(mark.status, .applied)
        XCTAssertEqual(mark.source, "S1")
        XCTAssertEqual(mark.comment, "duplicate of S9")
        XCTAssertEqual(mark.text, NoteFingerprint.read(forRecordingURL: media).text)
        XCTAssertEqual(try Data(contentsOf: sidecar), before, "bookkeeping never edits note sidecars")
        XCTAssertNil(store.pass(), "boundary is the dispatcher's responsibility after all checks")
    }

    func testListingWithoutReadingCannotMarkSources() async throws {
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 0)
        XCTAssertTrue(report.findings.contains { $0.contains("no get_note receipt") })
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testUnreviewedBacklogIsNotAutomaticallyRemarked() async throws {
        try await read()
        let report = await finish([])
        XCTAssertEqual(report.stored, 0, "a receipt alone is not a semantic decision")
        XCTAssertTrue(store.marks().isEmpty)
    }

    func testNewTranscriptAfterReadIsNotAcknowledged() async throws {
        try await read()
        try FileStore.mutateSidecar(at: sidecar) { $0["transcription"] = ["transcript": "new transcript"]; return true }
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 0)
        XCTAssertTrue(report.findings.contains { $0.contains("changed after get_note") })
    }

    func testTypedEditAfterReadIsNotAcknowledged() async throws {
        try await read()
        try "edited after the read".write(to: media, atomically: true, encoding: .utf8)
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 0)
        XCTAssertTrue(report.findings.contains { $0.contains("changed after get_note") })
    }

    func testUnchangedPendingDecisionRefreshesOnlyReviewedVersion() async throws {
        try registry(status: "pending")
        try store.update([media.lastPathComponent: .init(status: .pending, source: "S1", markedAt: .distantPast,
                                                       noteId: "note-id", text: "old fingerprint", analysis: "old")])
        try await read()
        let report = await finish(["S1"])
        XCTAssertEqual(report.findings, [])
        XCTAssertEqual(store.mark(forFile: media.lastPathComponent)?.status, .pending)
        XCTAssertEqual(store.mark(forFile: media.lastPathComponent)?.text, NoteFingerprint.read(forRecordingURL: media).text)
    }

    func testOldRegistryErrorDoesNotLoseValidReviewsButBlocksCleanFinish() async throws {
        try registry(extra: [["source_id": "S2", "path": "../recordings/missing.meta.json", "status": "pending"]])
        try await read()
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 1)
        XCTAssertTrue(report.findings.contains { $0.contains("S2") && $0.contains("missing") })
    }

    func testPrivateReadNeverProducesReceipt() async throws {
        _ = try await read(isPrivate: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: SecretaryReadReceipt.logURL(runID: task.id, store: store).path))
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 0)
    }

    func testConflictingExistingSourceIsNotOverwritten() async throws {
        try store.update([media.lastPathComponent: .init(status: .pending, source: "S99", markedAt: .distantPast,
                                                       noteId: "note-id", text: "old", analysis: "old")])
        try await read()
        let report = await finish(["S1"])
        XCTAssertEqual(report.stored, 0)
        XCTAssertEqual(store.mark(forFile: media.lastPathComponent)?.source, "S99")
    }

    func testMissingReviewedListAndMalformedRegistryFailClosed() async throws {
        let missing = await finish(nil)
        XCTAssertTrue(missing.findings.contains { $0.contains("reviewed_sources") })
        try registry(extra: [["source_id": "S1", "path": "../recordings/other.meta.json", "status": "noise"]])
        try await read()
        let duplicate = await finish(["S1"])
        XCTAssertEqual(duplicate.stored, 0)
        XCTAssertTrue(duplicate.findings.contains { $0.contains("duplicate registry") })
    }

    private var registryURL: URL { document.deletingPathExtension().appendingPathExtension("sources.json") }
    private func registryObject() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any])
    }
    private func writeRegistryObject(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: registryURL)
    }
    private func decide(_ status: String = "pending", reason: String = "Rechecked version") async -> SecretaryBookkeepingReport {
        let media = media
        return await SecretaryBookkeeping.finish(task: task,
            result: SecretaryResult(sourceDecisions: [.init(source: "S1", status: status, reason: reason)]),
            store: store, recordings: { [media] })
    }
    private func prepareManaged() throws {
        try "# Managed".write(to: root.appendingPathComponent("secretary/protocol.md"), atomically: true, encoding: .utf8)
        let protocolFolder = root.appendingPathComponent("secretary/protocol")
        try FileManager.default.createDirectory(at: protocolFolder, withIntermediateDirectories: true)
        try "# Managed".write(to: protocolFolder.appendingPathComponent("managed-review.md"), atomically: true, encoding: .utf8)
        let directory = task.workspace.runDirectory(task.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SecretaryContext.write(task: task, directory: directory)
    }

    func testDecisionsUpdateHashesHistoryAndCountsPreservingUnownedFields() async throws {
        try registry(status: "pending", extra: [["source_id": "S2", "path": "../recordings/old.meta.json", "status": "noise", "removed_from_wimm": true, "opaque": ["brackets": "[}\" русский"]]])
        var object = try registryObject()
        object["scope"] = ["keep": "unchanged"]; object["prepared_on"] = "2026-01-01"; object["period_end"] = "2026-10-20"
        object["batches"] = [["kind": "old", "opaque": "[,]{}\"текст"]]
        var sources = object["sources"] as! [[String: Any]]
        sources[0]["sha256"] = "previous-hash"; sources[0]["triage"] = ["private": [1, 2, 3]]
        sources[0]["original_image_viewed"] = true; object["sources"] = sources
        try writeRegistryObject(object)
        let before = try Data(contentsOf: registryURL)
        func untouchedRow(_ data: Data) throws -> Data {
            let patch = try SecretaryJSONPatch(data)
            let range = try XCTUnwrap(patch.members(0..<data.count).first { $0.key == "sources" }?.value)
            let row = try patch.elements(range)[1]
            return data.subdata(in: row)
        }
        let untouched = try untouchedRow(before)
        try await read()
        let sidecarBefore = try Data(contentsOf: sidecar)
        let report = await decide("noise", reason: "Explicit microphone test")
        XCTAssertEqual(report.stored, 1)
        XCTAssertEqual(report.registryUpdated, 1)
        XCTAssertEqual(report.findings, [])
        let after = try registryObject(), updated = (after["sources"] as! [[String: Any]])[0]
        XCTAssertEqual(updated["sha256"] as? String, SecretaryBookkeeping.digest(sidecarBefore))
        XCTAssertEqual(updated["status"] as? String, "noise")
        XCTAssertEqual(updated["read_scope"] as? String, "all_available_text_recheck")
        XCTAssertEqual(updated["original_image_viewed"] as? Bool, true)
        XCTAssertEqual((updated["triage"] as? [String: [Int]])?["private"], [1, 2, 3])
        XCTAssertEqual(after["prepared_on"] as? String, "2026-01-01")
        XCTAssertEqual(after["period_end"] as? String, "2026-10-20")
        XCTAssertEqual(after["counts"] as? [String: Int], ["noise": 2])
        let batches = after["batches"] as! [[String: Any]]
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0]["opaque"] as? String, "[,]{}\"текст")
        let history = try XCTUnwrap(batches.last?["revised_sources"] as? [[String: Any]])
        XCTAssertEqual(history.first?["previous_sha256"] as? String, "previous-hash")
        XCTAssertEqual(history.first?["previous_status"] as? String, "pending")
        XCTAssertEqual(try untouchedRow(Data(contentsOf: registryURL)), untouched, "unrelated rows retain their exact bytes")
        XCTAssertEqual(try Data(contentsOf: sidecar), sidecarBefore)
        XCTAssertNotNil(report.registryBackup)
        let stable = try Data(contentsOf: registryURL)
        let retry = await decide("noise", reason: "Explicit microphone test")
        XCTAssertEqual(retry.findings, [])
        XCTAssertEqual(retry.registryUpdated, 0)
        XCTAssertEqual(try Data(contentsOf: registryURL), stable, "finalization retries must not duplicate history")
    }

    func testMissingCitationDefinitionsAreAddedWithoutChangingProse() async throws {
        let body = "# Test\n\nFact [S1].\n"
        try body.write(to: document, atomically: true, encoding: .utf8)
        try await read()
        let report = await decide("applied")
        XCTAssertEqual(report.referencesAdded, 1)
        XCTAssertEqual(report.findings, [])
        let text = try String(contentsOf: document, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(body))
        XCTAssertTrue(text.contains("[S1]: ../recordings/\(sidecar.lastPathComponent)"))
        let retry = await decide("applied")
        XCTAssertEqual(retry.referencesAdded, 0)
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), text)
    }

    func testExistingWrongCitationIsReportedRatherThanRewritten() async throws {
        let body = "Fact [S1].\n\n[S1]: ../recordings/note.txt\n"
        try body.write(to: document, atomically: true, encoding: .utf8)
        try await read()
        let report = await decide("applied")
        XCTAssertEqual(report.referencesAdded, 0)
        XCTAssertTrue(report.findings.contains { $0.contains("different registry target") })
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), body)
    }

    func testUnknownCitationsAreNotInvented() async throws {
        try "Fact [S999].\n".write(to: document, atomically: true, encoding: .utf8)
        try await read()
        let report = await decide()
        XCTAssertEqual(report.referencesAdded, 0)
        XCTAssertTrue(report.findings.contains { $0.contains("[S999]") })
    }

    func testStaleVersionCannotChangeRegistryOrHistory() async throws {
        try await read()
        let before = try Data(contentsOf: registryURL)
        try "Changed while the agent was thinking".write(to: media, atomically: true, encoding: .utf8)
        let report = await decide("noise")
        XCTAssertEqual(report.stored, 0)
        XCTAssertEqual(report.registryUpdated, 0)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
        XCTAssertTrue(report.findings.contains { $0.contains("changed after get_note") })
    }

    func testManagedSourceRevisionsRequireDecisionsAndRejectDirectAgentEdits() async throws {
        try prepareManaged(); try await read()
        let missing = await finish(["S1"])
        XCTAssertEqual(missing.stored, 0)
        XCTAssertTrue(missing.findings.contains { $0.contains("require source_decisions") })
        var object = try registryObject(), rows = object["sources"] as! [[String: Any]]
        rows[0]["reason"] = "Agent changed the existing row directly"; object["sources"] = rows
        try writeRegistryObject(object)
        let rejected = await decide("noise")
        XCTAssertEqual(rejected.stored, 0)
        XCTAssertTrue(rejected.findings.contains { $0.contains("edited during the agent run") })
    }

    func testManagedSnapshotRejectsUnreviewedRowAndMetadataChanges() async throws {
        try registry(extra: [["source_id": "S2", "path": "../recordings/other.meta.json", "status": "pending", "reason": "original"]])
        var initial = try registryObject()
        initial["owner_field"] = "keep"
        initial["batches"] = [["historical": true]]
        try writeRegistryObject(initial)
        try prepareManaged(); try await read()
        var edited = initial, rows = edited["sources"] as! [[String: Any]]
        rows[1]["reason"] = "unreviewed change"; edited["sources"] = rows
        try writeRegistryObject(edited)
        let row = await decide("noise")
        XCTAssertEqual(row.stored, 0)
        XCTAssertTrue(row.findings.contains { $0.contains("S2") && $0.contains("edited during") })
        edited = initial; edited["owner_field"] = "changed"
        try writeRegistryObject(edited)
        let metadata = await decide("noise")
        XCTAssertEqual(metadata.stored, 0)
        XCTAssertTrue(metadata.findings.contains { $0.contains("Registry metadata owner_field") })
        edited = initial; edited["batches"] = []
        try writeRegistryObject(edited)
        let history = await decide("noise")
        XCTAssertEqual(history.stored, 0)
        XCTAssertTrue(history.findings.contains { $0.contains("history was rewritten") })
    }

    func testValidManagedDecisionUsesSnapshotAndCanBeRetried() async throws {
        try prepareManaged(); try await read()
        let result = await decide("noise")
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(result.registryUpdated, 1)
        XCTAssertEqual(result.stored, 1)
        let retry = await decide("noise")
        XCTAssertEqual(retry.findings, [])
        XCTAssertEqual(retry.registryUpdated, 0)
    }

    func testDuplicateDecisionWithoutValidTargetIsRejected() async throws {
        try await read()
        let before = try Data(contentsOf: registryURL)
        let result = await decide("duplicate")
        XCTAssertEqual(result.stored, 0)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
        XCTAssertTrue(result.findings.contains { $0.contains("valid merged_with") })
    }

    func testConcurrentRegistryChangeIsNotOverwritten() async throws {
        try await read()
        let media = media
        let result = await SecretaryBookkeeping.finish(task: task,
            result: SecretaryResult(sourceDecisions: [.init(source: "S1", status: "noise", reason: "test")]),
            store: store, recordings: {
                var object = try! self.registryObject(); object["external_change"] = true
                try! self.writeRegistryObject(object)
                return [media]
            })
        XCTAssertEqual(result.stored, 0)
        XCTAssertTrue(result.findings.contains { $0.contains("changed during finalization") })
        XCTAssertEqual(try registryObject()["external_change"] as? Bool, true)
        XCTAssertEqual((try registryObject()["sources"] as? [[String: Any]])?.first?["status"] as? String, "applied")
    }


    func testDryFinalizationPreviewsRegistryAndReferencesWithoutWrites() async throws {
        try "Fact [S1].\n".write(to: document, atomically: true, encoding: .utf8)
        try await read()
        let beforeRegistry = try Data(contentsOf: registryURL), beforeDoc = try Data(contentsOf: document)
        let media = media
        let report = await SecretaryBookkeeping.finish(task: task,
            result: SecretaryResult(sourceDecisions: [.init(source: "S1", status: "noise", reason: "test")]),
            store: store, recordings: { [media] }, applyChanges: false)
        XCTAssertEqual(report.findings, [])
        XCTAssertEqual(report.registryUpdated, 1)
        XCTAssertEqual(report.referencesAdded, 1)
        XCTAssertEqual(try Data(contentsOf: registryURL), beforeRegistry)
        XCTAssertEqual(try Data(contentsOf: document), beforeDoc)
        XCTAssertTrue(store.marks().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.workspace.runDirectory(task.id).appendingPathComponent("registry-before-host.json").path))
    }

    func testDeletionReconciliationNeedsPositiveTrashEvidenceAndNoActivePrimary() throws {
        let active = root.appendingPathComponent("recordings"), trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let source = ["source_id": "S1", "path": "../recordings/deleted.meta.json", "note_file": "deleted.m4a", "status": "pending", "reason": "keep reason"]
        XCTAssertTrue(SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: active, trash: trash).isEmpty)
        let trashedSidecar = trash.appendingPathComponent("deleted.meta.json")
        try FileStore.mutateSidecar(at: trashedSidecar) { $0["trashed"] = true; $0["recordingId"] = "verified-identity"; return true }
        let updates = SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: active, trash: trash)
        XCTAssertNotNil(updates["S1"]?["removed_from_wimm"])
        XCTAssertEqual(updates["S1"]?["status"] as? String, "pending")
        XCTAssertEqual(updates["S1"]?["reason"] as? String, "keep reason")
        try Data().write(to: active.appendingPathComponent("deleted.m4a"))
        XCTAssertTrue(SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: active, trash: trash).isEmpty)
    }

    func testDeletionReconciliationAcceptsTrashedSidecarWithoutTrashFlag() throws {
        // Sync tombstones and manual moves put the sidecar in Trash without `trashed`.
        let active = root.appendingPathComponent("recordings"), trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileStore.mutateSidecar(at: trash.appendingPathComponent("moved.meta.json")) { $0["recordingId"] = "moved-identity"; return true }
        let source = ["source_id": "S1", "path": "../recordings/moved.meta.json", "status": "noise"]
        let removed = try XCTUnwrap(SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: active, trash: trash)["S1"]?["removed_from_wimm"] as? [String: Any])
        XCTAssertEqual(removed["recording_id"] as? String, "moved-identity")
        XCTAssertTrue(removed["trashed_at"] is NSNull, "no invented date when the delete path did not record one")
        let wrong = ["source_id": "S1", "path": "../recordings/moved.meta.json", "status": "noise", "recording_id": "other"]
        XCTAssertTrue(SecretaryLibraryReconciliation.removals(sources: [wrong], task: task, active: active, trash: trash).isEmpty)
    }

    func testDeletionReconciliationDoesNotTrustTrashFromAnotherLibrary() throws {
        let source = ["source_id": "S1", "path": "../recordings/missing.meta.json", "status": "pending"]
        let other = root.appendingPathComponent("other/Recordings")
        XCTAssertTrue(SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: other, trash: root).isEmpty)
    }
    func testExplicitDuplicateTargetIsAppliedByTheHost() async throws {
        try registry(extra: [["source_id": "S2", "path": "../recordings/old.meta.json", "status": "applied", "removed_from_wimm": true]])
        try await read()
        let media = media
        let result = await SecretaryBookkeeping.finish(task: task,
            result: SecretaryResult(sourceDecisions: [.init(source: "S1", status: "duplicate", reason: "same episode", mergedWith: ["S2"])]),
            store: store, recordings: { [media] })
        XCTAssertEqual(result.findings, [])
        XCTAssertEqual(store.mark(forFile: media.lastPathComponent)?.status, .applied)
        XCTAssertEqual(store.mark(forFile: media.lastPathComponent)?.comment, "duplicate of S2")
        XCTAssertEqual((try registryObject()["sources"] as? [[String: Any]])?.first?["status"] as? String, "duplicate")
    }
    func testDeletionReconciliationResolvesSymlinkParentOfMissingFile() throws {
        let active = root.appendingPathComponent("actual-library")
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: media.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: media.deletingLastPathComponent(), withDestinationURL: active)
        try FileStore.mutateSidecar(at: trash.appendingPathComponent("deleted.meta.json")) {
            $0["trashed"] = true; $0["recordingId"] = "identity"; return true
        }
        let source = ["source_id": "S1", "path": "../recordings/deleted.meta.json", "status": "pending"]
        XCTAssertNotNil(SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: active, trash: trash)["S1"])
    }

    func testDeletionReconciliationRecognizesDirectoryCaseAliases() throws {
        let active = root.appendingPathComponent("Recordings")
        guard FileManager.default.fileExists(atPath: active.path) else { throw XCTSkip("case-sensitive filesystem") }
        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileStore.mutateSidecar(at: trash.appendingPathComponent("deleted.meta.json")) {
            $0["trashed"] = true; $0["recordingId"] = "identity"; return true
        }
        let source = ["source_id": "S1", "path": "../recordings/deleted.meta.json", "status": "pending"]
        XCTAssertNotNil(SecretaryLibraryReconciliation.removals(sources: [source], task: task, active: active, trash: trash)["S1"])
    }

}
