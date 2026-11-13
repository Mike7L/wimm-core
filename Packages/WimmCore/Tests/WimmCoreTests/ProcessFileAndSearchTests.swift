import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

// MARK: - ProcessFileUseCase Tests

final class ProcessFileUseCaseTests: XCTestCase {
    private var tempDir: URL!
    private var adapter: FileSystemAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-processfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("Recordings"),
            withIntermediateDirectories: true
        )
        adapter = FileSystemAdapter(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private func makeUseCase(
        transcriber: TranscriptionPort = StubTranscriber(fixedText: "hello"),
        analyzer: AnalysisPort = StubAnalysis()
    ) -> ProcessFileUseCase {
        ProcessFileUseCase(storage: adapter, transcription: transcriber, analysis: analyzer)
    }

    /// Creates a dummy audio file at Recordings/<name> and returns its URL.
    @discardableResult
    private func writeAudio(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("Recordings/\(name)")
        try Data("audio".utf8).write(to: url)
        return url
    }

    // MARK: - Tests

    func testProcessFile_newFile_transcribesAndAnalyzes() async throws {
        let useCase = makeUseCase(transcriber: StubTranscriber(fixedText: "hello world"))
        let audioURL = try writeAudio(named: "test.m4a")

        let result = try await useCase.execute(fileURL: audioURL, transcriptionMode: .ifMissing, dryRun: false)

        XCTAssertEqual(result.note.status, .completed)
        XCTAssertTrue(result.didTranscribe)
        XCTAssertEqual(result.note.text, "hello world")
        XCTAssertNotNil(result.note.card)
    }

    func testProcessFile_existingNoteWithText_skipsTranscription() async throws {
        let note = try await adapter.saveRecording(
            data: Data("audio".utf8),
            fileName: "has_text.m4a",
            initialText: "existing transcription"
        )
        let useCase = makeUseCase(transcriber: StubTranscriber(fixedText: "should not be used"))
        let audioURL = tempDir.appendingPathComponent("Recordings/has_text.m4a")

        let result = try await useCase.execute(fileURL: audioURL, transcriptionMode: .ifMissing, dryRun: false)

        XCTAssertEqual(result.note.id, note.id)
        XCTAssertFalse(result.didTranscribe, "Should not transcribe when text is present and mode=ifMissing")
        XCTAssertEqual(result.note.status, .completed)
    }

    func testProcessFile_alwaysMode_retranscribes() async throws {
        _ = try await adapter.saveRecording(
            data: Data("audio".utf8),
            fileName: "old_text.m4a",
            initialText: "old transcription"
        )
        let useCase = makeUseCase(transcriber: StubTranscriber(fixedText: "new transcription"))
        let audioURL = tempDir.appendingPathComponent("Recordings/old_text.m4a")

        let result = try await useCase.execute(fileURL: audioURL, transcriptionMode: .always, dryRun: false)

        XCTAssertTrue(result.didTranscribe)
        XCTAssertEqual(result.note.text, "new transcription")
    }

    func testProcessFile_dryRun_doesNotPersist() async throws {
        let useCase = makeUseCase(transcriber: StubTranscriber(fixedText: "transcribed"))
        let audioURL = try writeAudio(named: "dry.m4a")

        let result = try await useCase.execute(fileURL: audioURL, transcriptionMode: .ifMissing, dryRun: true)

        XCTAssertEqual(result.note.status, .completed)
        let all = try await adapter.loadAll()
        XCTAssertTrue(all.isEmpty, "dry-run should not write to disk")
    }

    func testProcessFile_analysisFailure_marksAsFailed() async throws {
        let useCase = makeUseCase(
            transcriber: StubTranscriber(fixedText: "text"),
            analyzer: FailingAnalysis(domain: "Test", code: 1, message: "analysis failed")
        )
        let audioURL = try writeAudio(named: "fail.m4a")

        do {
            _ = try await useCase.execute(fileURL: audioURL, transcriptionMode: .ifMissing, dryRun: false)
            XCTFail("Expected error to be thrown")
        } catch {
            let all = try await adapter.loadAll()
            let saved = all.first { $0.audioPath?.contains("fail") == true }
            if case let .failed(reason, _) = saved?.status {
                XCTAssertTrue(reason.contains("analysis failed"), "Got: \(reason)")
            } else {
                XCTFail("Expected note to be marked as failed, got: \(String(describing: saved?.status))")
            }
        }
    }
}

// MARK: - SearchNotesUseCase Tests

final class SearchNotesUseCaseTests: XCTestCase {
    private var tempDir: URL!
    private var adapter: FileSystemAdapter!
    private var useCase: SearchNotesUseCase!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        adapter = FileSystemAdapter(rootDirectory: tempDir)
        useCase = SearchNotesUseCase(storage: adapter)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSearch_byTextMatches() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "a.m4a", initialText: "swift programming")
        let n2 = try await adapter.saveRecording(data: Data(), fileName: "b.m4a", initialText: "python scripting")
        _ = n2

        var c1 = n1; c1.status = .completed
        c1.card = AnalysisCard(title: "Swift Note", summary: "s", tags: [], projects: [])
        try await adapter.updateNote(c1)

        let results = try await useCase.execute(query: NoteSearchQuery(text: "swift"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, n1.id)
    }

    func testSearch_byTag() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "t1.m4a", initialText: "a")
        let n2 = try await adapter.saveRecording(data: Data(), fileName: "t2.m4a", initialText: "b")

        var c1 = n1; c1.status = .completed
        c1.card = AnalysisCard(title: "T1", summary: "s", tags: ["ios", "swift"], projects: [])
        try await adapter.updateNote(c1)

        var c2 = n2; c2.status = .completed
        c2.card = AnalysisCard(title: "T2", summary: "s", tags: ["android"], projects: [])
        try await adapter.updateNote(c2)

        let results = try await useCase.execute(query: NoteSearchQuery(tag: "ios"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, n1.id)
    }

    func testSearch_byProject() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "p1.m4a", initialText: "x")
        var c1 = n1; c1.status = .completed
        c1.card = AnalysisCard(title: "P1", summary: "s", tags: [], projects: ["Wimm", "WIMM"])
        try await adapter.updateNote(c1)

        let n2 = try await adapter.saveRecording(data: Data(), fileName: "p2.m4a", initialText: "y")
        var c2 = n2; c2.status = .completed
        c2.card = AnalysisCard(title: "P2", summary: "s", tags: [], projects: ["Other"])
        try await adapter.updateNote(c2)

        let results = try await useCase.execute(query: NoteSearchQuery(project: "WIMM"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, n1.id)
    }

    func testSearch_byStatus_completed() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "s1.m4a", initialText: "a")
        let n2 = try await adapter.saveRecording(data: Data(), fileName: "s2.m4a", initialText: "b")

        var c1 = n1; c1.status = .completed
        c1.card = AnalysisCard(title: "ok", summary: "s", tags: [], projects: [])
        try await adapter.updateNote(c1)

        // n2 stays .pendingAnalysis

        let results = try await useCase.execute(query: NoteSearchQuery(status: .completed))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, n1.id)
        _ = n2
    }

    func testSearch_byStatus_failed() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "f1.m4a", initialText: "a")
        var failed = n1
        failed.status = .failed(reason: "oops", retryable: true)
        try await adapter.updateNote(failed)

        let _ = try await adapter.saveRecording(data: Data(), fileName: "ok.m4a", initialText: "b")

        let results = try await useCase.execute(query: NoteSearchQuery(status: .failed(reason: "", retryable: true)))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, n1.id)
    }

    func testSearch_withLimit() async throws {
        for i in 1...5 {
            _ = try await adapter.saveRecording(data: Data(), fileName: "lim\(i).m4a", initialText: "text \(i)")
        }
        let results = try await useCase.execute(query: NoteSearchQuery(limit: 3))
        XCTAssertEqual(results.count, 3)
    }

    func testSearch_emptyQuery_returnsAll() async throws {
        for i in 1...4 {
            _ = try await adapter.saveRecording(data: Data(), fileName: "all\(i).m4a", initialText: "t\(i)")
        }
        let results = try await useCase.execute(query: NoteSearchQuery())
        XCTAssertEqual(results.count, 4)
    }

    func testSearch_caseInsensitive() async throws {
        let n1 = try await adapter.saveRecording(data: Data(), fileName: "ci.m4a", initialText: "SwiftUI Framework")
        var c1 = n1; c1.status = .completed
        c1.card = AnalysisCard(title: "SwiftUI", summary: "s", tags: ["SwiftUI"], projects: [])
        try await adapter.updateNote(c1)

        let byText = try await useCase.execute(query: NoteSearchQuery(text: "swiftui"))
        XCTAssertEqual(byText.count, 1)

        let byTag = try await useCase.execute(query: NoteSearchQuery(tag: "swiftui"))
        XCTAssertEqual(byTag.count, 1)
    }

    func testSearch_loadNoteMatchingAudioPath() async throws {
        let n = try await adapter.saveRecording(data: Data(), fileName: "lookup.m4a", initialText: "test")

        let found = try await adapter.loadNote(matchingAudioPath: "lookup.m4a")
        XCTAssertEqual(found?.id, n.id)

        let notFound = try await adapter.loadNote(matchingAudioPath: "nonexistent.m4a")
        XCTAssertNil(notFound)
    }
}

// Test helpers are defined in TestDoubles.swift
