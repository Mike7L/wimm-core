import Foundation
import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmTUI

final class HUDCommandsTests: XCTestCase {
    private var tempDir: URL!
    private var storage: FileSystemAdapter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-hud-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        storage = FileSystemAdapter(rootDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testStartHUDRecordingInvokesTranscriberStart() throws {
        let transcriber = HUDTranscriberStub(finalText: "hello")
        let state = try startHUDRecording(transcriber: transcriber)

        XCTAssertEqual(transcriber.startCalls, 1)

        state.drainTask.cancel()
    }

    func testStartHUDRecordingCapturesLivePartialTranscript() async throws {
        let transcriber = HUDTranscriberStub(finalText: "hello")
        let state = try startHUDRecording(transcriber: transcriber)
        await state.drainTask.value

        let preview = await state.liveTranscript.preview(maxLength: 100)
        XCTAssertEqual(preview, "partial")
    }

    func testLiveTranscriptPreviewIsNilWhenEmpty() async {
        let transcript = HUDLiveTranscript()
        let preview = await transcript.preview(maxLength: 32)
        XCTAssertNil(preview)
    }

    func testLiveTranscriptPreviewTrimsWhitespace() async {
        let transcript = HUDLiveTranscript()
        await transcript.update(with: "   hello world   \n")
        let preview = await transcript.preview(maxLength: 64)
        XCTAssertEqual(preview, "hello world")
    }

    func testLiveTranscriptPreviewUsesSuffixWhenTooLong() async {
        let transcript = HUDLiveTranscript()
        await transcript.update(with: "abcdefghijklmnopqrstuvwxyz")
        let preview = await transcript.preview(maxLength: 5)
        XCTAssertEqual(preview, "vwxyz")
    }

    func testHudStatusLabelMapping() {
        XCTAssertEqual(hudStatusLabel(for: .pendingAnalysis), "PENDING")
        XCTAssertEqual(hudStatusLabel(for: .completed), "DONE")
        XCTAssertEqual(hudStatusLabel(for: .failed(reason: "x", retryable: true)), "FAILED")
    }

    func testHudInputActionMapsEnglishAndRussianLayoutKeys() {
        XCTAssertEqual(hudInputAction(for: "x"), .toggleRecording)
        XCTAssertEqual(hudInputAction(for: "ч"), .toggleRecording)
        XCTAssertEqual(hudInputAction(for: "w"), .toggleRecording)
        XCTAssertEqual(hudInputAction(for: "ц"), .toggleRecording)
        XCTAssertEqual(hudInputAction(for: "m"), .requestEditLastTranscript)
        XCTAssertEqual(hudInputAction(for: "ь"), .requestEditLastTranscript)
        XCTAssertEqual(hudInputAction(for: "d"), .deleteLastNote)
        XCTAssertEqual(hudInputAction(for: "в"), .deleteLastNote)
        XCTAssertEqual(hudInputAction(for: "q"), .close)
        XCTAssertEqual(hudInputAction(for: "й"), .close)
        XCTAssertEqual(hudInputAction(for: "X"), .exitApp)
        XCTAssertEqual(hudInputAction(for: "Ч"), .exitApp)
        XCTAssertEqual(hudInputAction(for: "?"), .toggleHelp)
    }

    func testHudInputActionMapsCtrlC() {
        let ctrlC = Character(UnicodeScalar(3)!)
        XCTAssertEqual(hudInputAction(for: ctrlC), .interrupt)
    }

    func testHudInputActionUnknownForBracket() {
        XCTAssertNil(hudInputAction(for: "["))
    }

    func testHudInputActionUppercaseCIsUnknown() {
        XCTAssertNil(hudInputAction(for: "C"))
    }

    func testHudDisplayTitlePrefersCardTitleThenTitleThenTextFallback() {
        var note = CapturedNote(
            id: UUID(),
            createdAt: Date(),
            text: "text fallback",
            audioPath: nil,
            status: .pendingAnalysis
        )

        note.card = AnalysisCard(title: "Card title", summary: "", tags: [], projects: [])
        XCTAssertEqual(hudDisplayTitle(for: note), "Card title")

        note.card = nil
        note.title = "Note title"
        XCTAssertEqual(hudDisplayTitle(for: note), "Note title")

        note.title = nil
        note.text = "  first line\nsecond line  "
        XCTAssertEqual(hudDisplayTitle(for: note), "first line second line")

        note.text = "   \n  "
        XCTAssertEqual(hudDisplayTitle(for: note), "(empty)")
    }

    func testMakeHUDReviewStateUsesNoteCreatedAtAndPreview() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let note = CapturedNote(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            createdAt: createdAt,
            text: "  first line\nsecond line  ",
            audioPath: nil,
            status: .pendingAnalysis
        )

        let state = makeHUDReviewState(from: note)
        XCTAssertEqual(state.shortID, "11111111")
        XCTAssertEqual(state.savedAt, createdAt)
        XCTAssertEqual(state.preview, "first line second line")
    }

    func testMakeHUDReviewStateShowsEmptyFallback() {
        let note = CapturedNote(
            id: UUID(),
            createdAt: Date(),
            text: " \n ",
            audioPath: nil,
            status: .pendingAnalysis
        )

        let state = makeHUDReviewState(from: note)
        XCTAssertEqual(state.preview, "(empty transcript)")
    }

    func testHudPreferredRecentNotesPrioritizesNonEmptyOverFailedEmpty() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let failedEmptyNew = CapturedNote(
            id: UUID(),
            createdAt: base.addingTimeInterval(30),
            text: "",
            audioPath: nil,
            status: .failed(reason: "x", retryable: true)
        )
        let failedEmptyOld = CapturedNote(
            id: UUID(),
            createdAt: base.addingTimeInterval(20),
            text: "",
            audioPath: nil,
            status: .failed(reason: "x", retryable: false)
        )
        let realRecent = CapturedNote(
            id: UUID(),
            createdAt: base.addingTimeInterval(10),
            text: "meaningful",
            audioPath: nil,
            status: .pendingAnalysis
        )

        let sorted = [failedEmptyNew, failedEmptyOld, realRecent]
        let picked = hudPreferredRecentNotes(from: sorted, limit: 2)

        XCTAssertEqual(picked.count, 2)
        XCTAssertEqual(picked[0].id, realRecent.id)
        XCTAssertEqual(picked[1].id, failedEmptyNew.id)
    }

    func testHudIsEmptyFailedPlaceholderDetection() {
        let failedEmpty = CapturedNote(
            id: UUID(),
            createdAt: Date(),
            text: " \n ",
            audioPath: nil,
            status: .failed(reason: "x", retryable: true)
        )
        XCTAssertTrue(hudIsEmptyFailedPlaceholder(failedEmpty))

        var withTitle = failedEmpty
        withTitle.title = "Has title"
        XCTAssertFalse(hudIsEmptyFailedPlaceholder(withTitle))

        let pending = CapturedNote(
            id: UUID(),
            createdAt: Date(),
            text: "",
            audioPath: nil,
            status: .pendingAnalysis
        )
        XCTAssertFalse(hudIsEmptyFailedPlaceholder(pending))
    }

    func testStopHUDRecordingSavesNoteAndNotifiesWhenAutoProcessEnabled() async throws {
        let transcriber = HUDTranscriberStub(finalText: "hud text", audioData: Data([1, 2, 3]))
        var state: HUDRecordingState? = try startHUDRecording(transcriber: transcriber)

        let notifier = NotificationCounter()
        let note = try await stopHUDRecording(
            transcriber: transcriber,
            storage: storage,
            recordingState: &state,
            autoProcessAfterRecord: true,
            notifyNewTask: { await notifier.increment() }
        )

        XCTAssertNil(state)
        XCTAssertEqual(transcriber.stopCalls, 1)
        let notifyCount = await notifier.currentValue()
        XCTAssertEqual(notifyCount, 1)
        XCTAssertEqual(note.text, "hud text")
        XCTAssertNotNil(note.audioPath)
        XCTAssertTrue(note.audioPath?.hasPrefix("hud_recording_") == true)
        XCTAssertTrue(note.audioPath?.hasSuffix(".m4a") == true)

        let all = try await storage.loadAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, note.id)
        XCTAssertEqual(all[0].text, "hud text")
        XCTAssertEqual(all[0].status, .pendingAnalysis)
    }

    func testStopHUDRecordingDoesNotNotifyWhenAutoProcessDisabled() async throws {
        let transcriber = HUDTranscriberStub(finalText: "hud text")
        var state: HUDRecordingState? = try startHUDRecording(transcriber: transcriber)

        let notifier = NotificationCounter()
        _ = try await stopHUDRecording(
            transcriber: transcriber,
            storage: storage,
            recordingState: &state,
            autoProcessAfterRecord: false,
            notifyNewTask: { await notifier.increment() }
        )

        XCTAssertNil(state)
        let notifyCount = await notifier.currentValue()
        XCTAssertEqual(notifyCount, 0)
    }

    func testStopHUDRecordingWithoutActiveStateThrows() async throws {
        let transcriber = HUDTranscriberStub(finalText: "hud text")
        var state: HUDRecordingState?

        do {
            _ = try await stopHUDRecording(
                transcriber: transcriber,
                storage: storage,
                recordingState: &state,
                autoProcessAfterRecord: false
            )
            XCTFail("Expected stopHUDRecording to throw when there is no active recording state.")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "WimmHUD")
            XCTAssertEqual(nsError.code, 1)
        }
    }

    func testStopHUDRecordingPropagatesTranscriberError() async throws {
        let transcriber = HUDTranscriberStub(finalText: "hud text", stopError: NSError(
            domain: "HUDTest",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "stop failed"]
        ))
        var state: HUDRecordingState? = try startHUDRecording(transcriber: transcriber)

        do {
            _ = try await stopHUDRecording(
                transcriber: transcriber,
                storage: storage,
                recordingState: &state,
                autoProcessAfterRecord: false
            )
            XCTFail("Expected stopHUDRecording to throw transcriber error.")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "HUDTest")
            XCTAssertEqual(nsError.code, 42)
        }
    }
}

private final class HUDTranscriberStub: TranscriptionPort, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private let finalText: String
    private let audioData: Data
    private let stopError: NSError?

    init(finalText: String, audioData: Data = Data(), stopError: NSError? = nil) {
        self.finalText = finalText
        self.audioData = audioData
        self.stopError = stopError
    }

    func startStreamingCapture() throws -> AsyncThrowingStream<String, Error> {
        lock.withLock { startCalls += 1 }
        return AsyncThrowingStream { continuation in
            continuation.yield("partial")
            continuation.finish()
        }
    }

    func stopCapture() async throws -> (audioData: Data, finalText: String) {
        lock.withLock { stopCalls += 1 }
        if let stopError { throw stopError }
        return (audioData, finalText)
    }

    func transcribeFile(at fileURL: URL) async throws -> String {
        finalText
    }
}

private actor NotificationCounter {
    private var value = 0
    func increment() { value += 1 }
    func currentValue() -> Int { value }
}
