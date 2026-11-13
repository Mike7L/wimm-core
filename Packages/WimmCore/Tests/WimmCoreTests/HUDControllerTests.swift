import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure

final class HUDControllerTests: XCTestCase {
    private var tempDir: URL!
    private var storage: FileSystemAdapter!
    private var queueSupervisor: QueueSupervisor!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-hud-controller-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = FileSystemAdapter(rootDirectory: tempDir)
        queueSupervisor = QueueSupervisor(storage: storage, analysis: StubAnalysis())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testControllerTogglesRecordingAndPersistsReviewState() async throws {
        let transcriber = HUDControllerTranscriberStub(finalText: "controller transcript")
        let controller = try await makeController(transcriber: transcriber, autoProcessAfterRecord: false)

        let initialState = await controller.viewState()
        XCTAssertEqual(initialState.mode, .idle)

        let startEffect = await controller.dispatch(.toggleRecording)
        XCTAssertEqual(startEffect, .none)
        var state = await controller.viewState()
        XCTAssertEqual(state.mode, .capture)
        XCTAssertEqual(state.lastMessage, "Recording started. Press x again to stop.")

        let stopEffect = await controller.dispatch(.toggleRecording)
        XCTAssertEqual(stopEffect, .none)
        state = await controller.viewState()
        XCTAssertEqual(state.mode, .review)
        XCTAssertEqual(state.reviewState?.preview, "controller transcript")
        XCTAssertTrue(state.lastMessage.contains("Recording saved as"))
    }

    func testControllerEditsAndDeletesReviewNote() async throws {
        let transcriber = HUDControllerTranscriberStub(finalText: "initial transcript")
        let controller = try await makeController(transcriber: transcriber, autoProcessAfterRecord: false)

        _ = await controller.dispatch(.toggleRecording)
        _ = await controller.dispatch(.toggleRecording)

        let effect = await controller.dispatch(.requestEditLastTranscript)
        let note = try await firstNote()
        XCTAssertEqual(
            effect,
            .promptTranscriptEdit(HUDTranscriptEditContext(shortID: note.shortID, currentText: "initial transcript"))
        )

        _ = await controller.dispatch(.applyTranscriptEdit("edited transcript"))
        var state = await controller.viewState()
        XCTAssertEqual(state.reviewState?.preview, "edited transcript")
        let editedNote = try await firstNote()
        XCTAssertEqual(editedNote.text, "edited transcript")

        _ = await controller.dispatch(.deleteLastNote)
        state = await controller.viewState()
        XCTAssertNil(state.reviewState)
        let notes = try await storage.loadAll()
        XCTAssertEqual(notes.count, 0)
    }

    func testControllerCompletesExternalActionWithMessages() async throws {
        let controller = try await makeController(
            transcriber: HUDControllerTranscriberStub(finalText: "ignored"),
            autoProcessAfterRecord: false
        )

        let effect = await controller.dispatch(.processQueue)
        XCTAssertEqual(effect, .runExternalAction(.processQueue))
        await controller.completeExternalAction(.processQueue, errorMessage: nil)
        let successState = await controller.viewState()
        XCTAssertEqual(successState.lastMessage, "Queue processing completed.")

        await controller.completeExternalAction(.exportNotes, errorMessage: "boom")
        let failureState = await controller.viewState()
        XCTAssertEqual(failureState.lastMessage, "Export failed: boom")
    }

    private func makeController(
        transcriber: TranscriptionPort,
        autoProcessAfterRecord: Bool
    ) async throws -> HUDController {
        let storage = try XCTUnwrap(storage)
        let queueSupervisor = try XCTUnwrap(queueSupervisor)
        let queueStatus = GetQueueStatusUseCase(storage: storage)
        let dependencies = HUDController.Dependencies(
            rootPath: tempDir.path,
            storage: storage,
            transcriber: transcriber,
            queueSupervisor: queueSupervisor,
            loadSnapshot: { [storage] in
                let notes = try await storage.loadAll()
                let queue = try await queueStatus.execute()
                return HUDSnapshotService.makeSnapshot(notes: notes, queue: queue)
            }
        )
        return try await HUDController.bootstrap(
            dependencies: dependencies,
            autoProcessAfterRecord: autoProcessAfterRecord
        )
    }

    private func firstNote() async throws -> CapturedNote {
        let notes = try await storage.loadAll()
        return try XCTUnwrap(notes.first)
    }
}

private final class HUDControllerTranscriberStub: TranscriptionPort, @unchecked Sendable {
    private let finalText: String

    init(finalText: String) {
        self.finalText = finalText
    }

    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("partial transcript")
            continuation.finish()
        }
    }

    func stopCapture() async throws -> (audioData: Data, finalText: String) {
        (Data([1, 2, 3]), finalText)
    }

    func transcribeFile(at fileURL: URL) async throws -> String {
        finalText
    }
}
