import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

final class UseCasesTests: XCTestCase {
    private var tempDir: URL!
    private var adapter: FileSystemAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-usecases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        adapter = FileSystemAdapter(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testListAndReadUseCases() async throws {
        let note = try await adapter.saveRecording(data: Data(), fileName: "sample.m4a", initialText: "hello")

        let listUseCase = ListNotesUseCase(storage: adapter)
        let readUseCase = ReadNoteUseCase(storage: adapter)

        let list = try await listUseCase.execute()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, note.id)

        let read = try await readUseCase.execute(id: note.id)
        XCTAssertEqual(read?.id, note.id)

        let byPrefix = try await readUseCase.execute(idPrefix: String(note.id.uuidString.prefix(8)))
        XCTAssertEqual(byPrefix?.id, note.id)
    }

    func testGetQueueStatusUseCaseBuildsSnapshot() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "q1.m4a", initialText: "p")
        let n2 = try await adapter.saveRecording(data: Data(), fileName: "q2.m4a", initialText: "c")
        let n3 = try await adapter.saveRecording(data: Data(), fileName: "q3.m4a", initialText: "f1")
        let n4 = try await adapter.saveRecording(data: Data(), fileName: "q4.m4a", initialText: "f2")

        var pending = n1
        pending.status = .pendingAnalysis
        try await adapter.updateNote(pending)

        var completed = n2
        completed.status = .completed
        completed.card = AnalysisCard(title: "ok", summary: "ok", tags: [], projects: [])
        try await adapter.updateNote(completed)

        var failedRetryable = n3
        failedRetryable.status = .failed(reason: "rate limit", retryable: true)
        try await adapter.updateNote(failedRetryable)

        var failedNonRetryable = n4
        failedNonRetryable.status = .failed(reason: "invalid payload", retryable: false)
        try await adapter.updateNote(failedNonRetryable)

        let useCase = GetQueueStatusUseCase(storage: adapter)
        let snapshot = try await useCase.execute()

        XCTAssertEqual(snapshot.pendingCount, 1)
        XCTAssertEqual(snapshot.completedCount, 1)
        XCTAssertEqual(snapshot.failedRetryableCount, 1)
        XCTAssertEqual(snapshot.failedNonRetryableCount, 1)
        XCTAssertEqual(snapshot.failedItems.count, 2)
    }

    func testGenerateFailedReportUseCaseMarkdownAndCSV() async throws {
        let note = try await adapter.saveRecording(data: Data(), fileName: "r.m4a", initialText: "sample")
        var failed = note
        failed.status = .failed(reason: "rate limit", retryable: true)
        try await adapter.updateNote(failed)

        let useCase = GenerateFailedReportUseCase(storage: adapter)
        let md = try await useCase.execute(format: .md)
        XCTAssertTrue(md.contains("Failed Queue Report"))
        XCTAssertTrue(md.contains(note.id.uuidString))
        XCTAssertTrue(md.contains("rate limit"))

        let csv = try await useCase.execute(format: .csv)
        XCTAssertTrue(csv.contains("id,created_at,retryable,reason"))
        XCTAssertTrue(csv.contains(note.id.uuidString))
        XCTAssertTrue(csv.contains("true"))
    }

}

final class ProcessingWorkflowTests: XCTestCase {
    private var tempDir: URL!
    private var storage: FileSystemAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = FileSystemAdapter(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWorkflow_processesAllNotes() async throws {
        let n1 = try await storage.saveRecording(data: Data(), fileName: "wf1.m4a", initialText: "text one")
        let n2 = try await storage.saveRecording(data: Data(), fileName: "wf2.m4a", initialText: "text two")
        var pending1 = n1; pending1.status = .pendingAnalysis
        var pending2 = n2; pending2.status = .pendingAnalysis
        try await storage.updateNote(pending1)
        try await storage.updateNote(pending2)

        let analysis = StubAnalysis()
        let workflow = ProcessingWorkflow(storage: storage, analysis: analysis)

        actor ProgressCollector {
            var events: [(Int, Int)] = []
            func append(_ e: (Int, Int)) { events.append(e) }
        }
        let collector = ProgressCollector()
        let processed = try await workflow.run(notes: [pending1, pending2]) { done, total in
            await collector.append((done, total))
        }

        let progressEvents = await collector.events
        XCTAssertEqual(processed, 2)
        // One event per attempt, plus the initial zero — the batch call used to
        // report only 0 and total, which its own doc comment already contradicted.
        XCTAssertEqual(progressEvents.map(\.0), [0, 1, 2])
        XCTAssertTrue(progressEvents.allSatisfy { $0.1 == 2 })

        let notes = try await storage.loadAll()
        XCTAssertTrue(notes.allSatisfy { $0.status == .completed })
    }

    func testWorkflow_marksFailedNoteAsRetryable() async throws {
        let note = try await storage.saveRecording(data: Data(), fileName: "wf_err.m4a", initialText: "text")
        var pending = note; pending.status = .pendingAnalysis
        try await storage.updateNote(pending)

        let failing = FailingAnalysis(domain: "HTTP", code: 429)
        let workflow = ProcessingWorkflow(storage: storage, analysis: failing)
        do {
            _ = try await workflow.run(notes: [pending])
            XCTFail("Expected error to be thrown")
        } catch {
            // Expected
        }

        let reloaded = try await storage.loadAll()
        if case let .failed(_, retryable) = reloaded[0].status {
            XCTAssertTrue(retryable, "HTTP 429 should be retryable")
        } else {
            XCTFail("Expected .failed status")
        }
    }

    /// The point of analyzing per note: one note the model chokes on used to
    /// mark every sibling in the pass `.failed` and throw.
    func testWorkflow_oneFailingNoteDoesNotFailItsSiblings() async throws {
        let good = try await storage.saveRecording(
            data: Data(), fileName: "wf_ok.m4a", initialText: "analyzable")
        let bad = try await storage.saveRecording(
            data: Data(), fileName: "wf_poison.m4a", initialText: FailingOnTextAnalysis.poison)
        var pendingGood = good; pendingGood.status = .pendingAnalysis
        var pendingBad = bad; pendingBad.status = .pendingAnalysis
        try await storage.updateNote(pendingGood)
        try await storage.updateNote(pendingBad)

        let workflow = ProcessingWorkflow(storage: storage, analysis: FailingOnTextAnalysis())
        let processed = try await workflow.run(notes: [pendingBad, pendingGood])

        XCTAssertEqual(processed, 1, "The healthy note must still complete")

        let reloaded = try await storage.loadAll()
        let byName = Dictionary(uniqueKeysWithValues: reloaded.map {
            ($0.audioPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "", $0)
        })
        XCTAssertEqual(byName["wf_ok.m4a"]?.status, .completed)
        guard case .failed = byName["wf_poison.m4a"]?.status else {
            return XCTFail("The poison note should be the only failure")
        }
    }
}

/// Fails only for one specific text, so a pass can contain both outcomes.
private struct FailingOnTextAnalysis: AnalysisPort {
    static let poison = "POISON"

    func analyze(text: String) async throws -> AnalysisCard {
        guard text != Self.poison else {
            throw NSError(domain: "Analysis", code: 400)
        }
        return AnalysisCard(title: "ok", summary: "ok", tags: [], projects: [])
    }
}

// Analysis test doubles are defined in TestDoubles.swift
