import XCTest
import SwiftUI
import AppKit
@testable import WimmDocumentUI
@preconcurrency import AVFoundation
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class VikRequestTests: XCTestCase {
    func testAddressBoundariesAndASRSpellings() {
        for text in ["Эй, Алёна, ответь", "эйалёна ответь", "Думаю вслух. ЭЙ АЛЁНА: ответь", "Эй-алена! ответь", "Алёна, ответь", "Мысль до. Алена ответь"] {
            XCTAssertEqual(VikRequest.extract(from: text), "ответь", text)
        }
        XCTAssertEqual(VikRequest.extract(from: "Эй, Алёна"), "")
        XCTAssertEqual(VikRequest.extract(from: "Алёна"), "")
        XCTAssertEqual(VikRequest.preface(from: "Мысль до. Алёна, ответь"), "Мысль до.")
        for text in ["Алёной звали вчера", "Эй Алёнка, привет", "шейалёна ответь", "Обычная заметка"] {
            XCTAssertNil(VikRequest.extract(from: text), text)
        }
    }

    func testCodeTaskPhraseAndDraftLink() throws {
        XCTAssertNil(VikCodeTask.extract(from: "где клиенты?"))
        XCTAssertNil(VikCodeTask.extract(from: "у меня задача для кода"))
        XCTAssertNil(VikCodeTask.extract(from: "задача для кодекса: тест"))
        XCTAssertEqual(VikCodeTask.extract(from: "Задача для кода: почини отступ."), "почини отступ.")
        XCTAssertEqual(VikCodeTask.extract(from: "задачу для Claude Code — добавь тест"), "добавь тест")
        XCTAssertEqual(VikCodeTask.extract(from: "задача для клода"), "")
        XCTAssertEqual(VikRequest.preface(from: "Мысль до. Эй, Алёна, задача для кода: тест"), "Мысль до.")

        let prompt = VikCodeTask.prompt(task: "почини a+b & c", note: "Мысль до. Эй Алёна задача для кода почини a+b & c",
                                        source: "Recordings/x.m4a")
        XCTAssertTrue(prompt.contains("Мысль до."))
        let link = try XCTUnwrap(VikCodeTask.link(prompt: prompt, folder: "/tmp/my repo"))
        XCTAssertTrue(link.absoluteString.hasPrefix("claude://code/new?folder=/tmp/my%20repo&q="))
        XCTAssertFalse(link.absoluteString.contains("+"))
        let items = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "q" }?.value, prompt)
        XCTAssertNil(VikCodeTask.link(prompt: String(repeating: "я", count: VikCodeTask.promptLimit + 1), folder: nil))
    }

    func testSentencePiecesDoNotRepeatOrSplitDecimals() {
        var buffer = VikSentences()
        XCTAssertEqual(buffer.append("Версия 3."), [])
        XCTAssertEqual(buffer.append("5 работает. След"), ["Версия 3.5 работает."])
        XCTAssertEqual(buffer.append("ующий ответ!\nЕщё"), ["Следующий ответ!"])
        XCTAssertEqual(buffer.append("", final: true), ["Ещё"])
        XCTAssertEqual(buffer.append("", final: true), [])
    }
}

@MainActor
final class VikAssistantTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    func testOrdinaryNoteNeverWarmsOrSendsAndSilenceIsNotConsumed() {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.liveText = "Обычная мысль."
        h.assistant.tick()
        XCTAssertFalse(h.assistant.silenceDetected())
        XCTAssertEqual(h.capture.stops, 0)
        XCTAssertEqual(h.voice.prepares, 0)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testSilenceWaitsForFinalTextAndSendsFullCurrentThought() async throws {
        let h = VikHarness(document: "Клиенты приходят по рекомендации.")
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.capture.liveText = "Описание идеи. Эй Алёна где клиенты"
        XCTAssertTrue(h.assistant.silenceDetected())
        await waitUntil { h.capture.stops == 1 }
        XCTAssertEqual(h.assistant.phase, .finishing)
        XCTAssertTrue(h.assistant.status.contains("live-текст"))
        XCTAssertEqual(h.calls.count, 0)
        h.capture.finish(.success("Описание идеи. Эй Алёна где клиенты и с чего начать?"))
        await waitUntil { h.calls.count == 1 }
        XCTAssertEqual(h.calls[0].query, "где клиенты и с чего начать?")
        XCTAssertEqual(h.calls[0].note, "Описание идеи. Эй Алёна где клиенты и с чего начать?")
        XCTAssertTrue(h.calls[0].tools.contains("previous_note"))
        h.reply?.yield("Спроси знакомых. ")
        await waitUntil { h.voice.lines.count == 1 }
        h.voice.onStarted?()
        XCTAssertEqual(h.assistant.phase, .speaking)
        h.voice.onIdle?() // A playback gap before the stream ends cannot resume capture.
        XCTAssertEqual(h.capture.starts, 0)
        h.reply?.yield("Вот ответ [D1]."); h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        XCTAssertEqual(h.capture.starts, 0)
        h.voice.onIdle?()
        await waitUntil { h.capture.starts == 1 }
        let saved = try String(contentsOf: XCTUnwrap(h.assistant.savedReply), encoding: .utf8)
        XCTAssertTrue(saved.contains("Описание идеи."))
        XCTAssertTrue(saved.contains("Вот ответ [D1]."))
    }

    func testCodeTaskOpensDraftWithoutModelCallAndResumesCapture() async throws {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.capture.liveText = "Мысль до. Эй Алёна задача для кода почини отступ"
        XCTAssertTrue(h.assistant.silenceDetected())
        await waitUntil { h.capture.stops == 1 }
        XCTAssertTrue(h.opened.isEmpty) // Only the final live text may open a draft.
        h.capture.finish(.success("Мысль до. Эй, Алёна, задача для кода: почини отступ в HUD."))
        await waitUntil { h.assistant.savedReply != nil }
        XCTAssertEqual(h.calls.count, 0)
        XCTAssertEqual(h.opened.count, 1)
        let query = try XCTUnwrap(URLComponents(url: h.opened[0], resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "q" }?.value)
        XCTAssertTrue(query.contains("почини отступ в HUD."))
        XCTAssertTrue(query.contains("Мысль до."))
        XCTAssertTrue(h.assistant.answer.contains("Открыла черновик"))
        h.voice.onIdle?()
        await waitUntil { h.capture.starts == 1 }
    }

    func testCodeTaskWithoutTextOrInPrivateModeOpensNothing() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send("Эй Алёна задача для кода")
        await waitUntil { h.assistant.savedReply != nil }
        XCTAssertTrue(h.assistant.answer.contains("нет самой задачи"))
        h.capture.liveText = "Эй Алёна задача для кода: тест"
        h.privateMode = true
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .failed)
        XCTAssertTrue(h.opened.isEmpty)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testLiveTextStabilityAloneNeverSubmits() {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.liveText = "Эй Алёна ответь"
        for _ in 0..<200 { h.assistant.tick() }
        XCTAssertEqual(h.assistant.phase, .listening)
        XCTAssertEqual(h.capture.stops, 0)
        XCTAssertEqual(h.calls.count, 0)
        h.capture.liveText = "Эй Алёнка, привет"
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .idle)
    }

    func testBareAddressDoesNotConsumeSilenceOrStopCapture() {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.liveText = "Эй Алёна"
        h.assistant.sendNow()
        XCTAssertFalse(h.assistant.silenceDetected())
        XCTAssertEqual(h.capture.stops, 0)
    }

    func testFailedFinalASRNeverSendsDraft() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.send()
        await waitUntil { h.capture.stops == 1 }
        h.capture.finish(.failure(NSError(domain: "ASR", code: 1)))
        XCTAssertEqual(h.assistant.phase, .failed)
        XCTAssertTrue(h.assistant.errorMessage?.contains("не отправлен") == true)
        XCTAssertEqual(h.calls.count, 0)
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testFinalTextWithoutAddressNeverUsesPreviousDraft() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.send()
        await waitUntil { h.capture.stops == 1 }
        h.capture.finish(.success("Эй Алёнка, привет"))
        XCTAssertEqual(h.assistant.phase, .failed)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testFinalASRDeadlineFailsAndLateSuccessCannotRestartRequest() async {
        let h = VikHarness(timeout: .milliseconds(30))
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.send()
        await waitUntil { h.assistant.phase == .failed }
        XCTAssertTrue(h.assistant.errorMessage?.contains("вовремя") == true)
        h.capture.finish(.success("Эй Алёна поздний вопрос"))
        XCTAssertEqual(h.calls.count, 0)
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testCancelWhileWaitingDropsLateFinalText() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.send()
        await waitUntil { h.capture.stops == 1 }
        h.assistant.cancel()
        h.capture.finish(.success("Эй Алёна поздний вопрос"))
        XCTAssertEqual(h.calls.count, 0)
        XCTAssertEqual(h.assistant.phase, .idle)
    }

    func testUserStartBeforeScheduledCloseCannotStopTheNewNote() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send()
        h.capture.userStart() // Before the assistant's close task gets the main actor.
        let newFile = h.capture.recordingURL
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(h.capture.isRecording)
        XCTAssertEqual(h.capture.recordingURL, newFile)
        XCTAssertEqual(h.capture.stops, 0)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testShortPauseAfterQuestionSendsWithoutWaitingForNoteSplit() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.quietAfterSpeech = (2, 7)
        h.capture.liveText = "Эй Алёна" // A bare address waits for the question.
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .listening)
        h.capture.liveText = "Эй Алёна ответь"
        h.capture.quietAfterSpeech = (1, 7)
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .listening)
        h.capture.quietAfterSpeech = (1.5, 7)
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .finishing)
        await waitUntil { h.calls.count == 1 }
        XCTAssertEqual(h.capture.stops, 1)

        let open = VikHarness()
        defer { open.assistant.shutdown() }
        open.assistant.keepMicOpen = true
        open.capture.liveText = "Эй Алёна ответь"
        open.capture.quietAfterSpeech = (1.5, 3)
        open.assistant.tick()
        await waitUntil { open.calls.count == 1 }
        XCTAssertEqual(open.capture.stops, 0)
        XCTAssertTrue(open.capture.isRecording)
    }

    func testOpenMicrophoneRepliesWithoutClosingCapture() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.assistant.keepMicOpen = true
        h.capture.holdFinal = true
        h.capture.liveText = "Мысль. Эй Алёна где клиенты"
        XCTAssertFalse(h.assistant.silenceDetected(revision: 1)) // The host rolls the note itself.
        XCTAssertEqual(h.assistant.phase, .finishing)
        XCTAssertFalse(h.assistant.status.contains("Микрофон выключен"))
        h.capture.roll()
        h.capture.liveText = "Следующая мысль."
        h.assistant.tick()
        h.capture.finish(.success("Мысль. Эй Алёна где клиенты?"))
        await waitUntil { h.calls.count == 1 }
        XCTAssertEqual(h.calls[0].query, "где клиенты?")
        h.capture.holdFinal = false
        await h.capture.send() // An ordinary send of the next note does not cut the reply.
        XCTAssertTrue(h.assistant.isResponding)
        h.reply?.yield("Спроси знакомых."); h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        h.voice.onIdle?()
        XCTAssertEqual(h.assistant.phase, .idle)
        XCTAssertTrue(h.capture.isRecording)
        XCTAssertEqual(h.capture.stops, 0)
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testOpenMicrophoneSendButtonStopWordAndNewAddress() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.assistant.keepMicOpen = true
        h.send("Эй Алёна расскажи длинно")
        await waitUntil { h.calls.count == 1 }
        XCTAssertEqual(h.capture.stops, 0)
        h.reply?.yield("Первое предложение. ")
        await waitUntil { h.voice.lines.count == 1 }
        h.capture.liveText = "Угу, понятно."
        h.assistant.tick()
        XCTAssertTrue(h.assistant.isResponding)
        h.capture.liveText = "Угу, понятно. Стоп."
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .idle)
        h.reply?.yield("Второе предложение. ")
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(h.voice.lines.count, 1)

        h.capture.liveText = "Угу, понятно. Стоп. Эй Алёна а короче"
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .listening)
        XCTAssertFalse(h.assistant.silenceDetected(revision: 2))
        h.capture.roll()
        await waitUntil { h.calls.count == 2 }
        h.capture.liveText = "Эй Алёна другой вопрос" // Replaces the reply in flight.
        h.assistant.tick()
        XCTAssertEqual(h.assistant.phase, .listening)
        XCTAssertEqual(h.assistant.request, "другой вопрос")
    }

    func testLateFinalOfOldNoteNeverInterruptsNewSpeech() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.holdFinal = true
        h.send()
        await waitUntil { h.capture.stops == 1 }
        h.capture.userStart()
        h.capture.liveText = "Новая мысль, которую нельзя прерывать."
        let newFile = h.capture.recordingURL
        h.capture.finish(.success("Эй Алёна старый вопрос"))
        XCTAssertTrue(h.capture.isRecording)
        XCTAssertEqual(h.capture.recordingURL, newFile)
        XCTAssertEqual(h.capture.stops, 1)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testUserCaptureCommandStopsVoiceBeforeOpeningMicrophone() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send()
        await waitUntil { h.reply != nil }
        h.reply?.yield("Ответ. ")
        await waitUntil { h.voice.lines.count == 1 }
        h.voice.isPlaying = true
        h.capture.beforeMicrophone = { XCTAssertFalse(h.voice.isPlaying) }
        h.capture.userStart()
        XCTAssertEqual(h.assistant.phase, .idle)
        XCTAssertTrue(h.capture.isRecording)
        h.reply?.yield("Поздняя часть."); h.reply?.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.voice.lines, ["Ответ."])
    }

    func testExplicitStopAfterReplyBeforeQueuedResumeRevokesLease() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send()
        await waitUntil { h.reply != nil }
        h.reply?.yield("Ответ."); h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        h.voice.onIdle?() // Queues automatic start but doesn't execute it yet.
        h.capture.userStop() // Even a no-op Stop revokes that start.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.capture.starts, 0)
        XCTAssertFalse(h.capture.isRecording)
    }

    func testManualStopWaitsForFinalTextWithoutAutomaticResume() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.capture.liveText = "Эй Алёна ответь"
        h.capture.userStop()
        await waitUntil { h.reply != nil }
        h.reply?.yield("Ответ."); h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        h.voice.onIdle?()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testOldVoiceCallbackCannotFinishANewerExchange() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send()
        await waitUntil { h.reply != nil }
        let oldIdle = h.voice.onIdle
        h.assistant.cancel()
        h.capture.userStart()
        h.reply = nil
        h.send("Эй Алёна новый вопрос")
        await waitUntil { h.reply != nil }
        h.reply?.yield("Новый ответ."); h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        oldIdle?()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.capture.starts, 0)
        XCTAssertTrue(h.assistant.isResponding)
        h.voice.onIdle?()
        await waitUntil { h.capture.starts == 1 }
    }

    func testVoiceFailureKeepsTextAndDoesNotAutomaticallyResume() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send()
        await waitUntil { h.reply != nil }
        h.reply?.yield("Первое предложение. ")
        await waitUntil { h.voice.lines.count == 1 }
        h.voice.onFailure?()
        h.reply?.yield("Остальное читается с экрана."); h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        XCTAssertTrue(h.assistant.answer.contains("Остальное"))
        XCTAssertTrue(h.assistant.errorMessage?.contains("озвучить") == true)
        XCTAssertEqual(h.voice.lines, ["Первое предложение."])
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testPrivateModeBeforeCloseAndWhileWaitingForFinalText() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.privateMode = true
        h.send()
        XCTAssertEqual(h.assistant.phase, .failed)
        XCTAssertEqual(h.capture.stops, 0)
        h.privateMode = false
        h.capture.userStart()
        h.capture.holdFinal = true
        h.send()
        await waitUntil { h.capture.stops == 1 }
        h.privateMode = true
        h.capture.finish(.success("Эй Алёна ответь"))
        XCTAssertEqual(h.assistant.phase, .failed)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testPrivateModeDuringStreamStopsVoiceAndNeverResumes() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send()
        await waitUntil { h.reply != nil }
        h.privateMode = true
        h.assistant.tick()
        h.reply?.yield("Нельзя читать."); h.reply?.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.assistant.phase, .failed)
        XCTAssertEqual(h.voice.lines, [])
        XCTAssertEqual(h.capture.starts, 0)
    }

    func testOversizeNoteIsReportedInsteadOfTruncated() async {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send(String(repeating: "я", count: 33_000) + " Эй Алёна ответь")
        await waitUntil { h.assistant.phase == .failed }
        XCTAssertTrue(h.assistant.errorMessage?.contains("длинная") == true)
        XCTAssertEqual(h.calls.count, 0)
    }

    func testReplyCitationsBecomeShortLinks() {
        let id = "F5A1E77D-8076-0C9E-F8F8-55482231A7D3"
        let text = VikReplyText.attributed("Метки [N:\(id)] и блок [b360], ещё [N:unknown].") {
            $0 == id ? "заметка 19:21" : nil
        }
        XCTAssertEqual(String(text.characters), "Метки заметка 19:21 и блок b360, ещё заметка.")
        let links = text.runs.compactMap(\.link?.absoluteString)
        XCTAssertEqual(links, ["wimm-hud://note/\(id)", "wimm-hud://doc/b360"])
    }

    func testDismissHidesFinishedReplyButKeepsSavedFile() async throws {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send("Эй Алёна с чего начать?")
        await waitUntil { h.reply != nil }
        h.assistant.dismiss()
        XCTAssertFalse(h.assistant.request.isEmpty, "a running reply is not dismissed")
        h.reply?.yield("Начни с малого.")
        h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        let saved = try XCTUnwrap(h.assistant.savedReply)
        h.voice.onStarted?(); h.voice.onIdle?()
        await waitUntil { h.assistant.phase == .idle }
        h.assistant.dismiss()
        XCTAssertTrue(h.assistant.request.isEmpty)
        XCTAssertTrue(h.assistant.answer.isEmpty)
        XCTAssertNil(h.assistant.savedReply)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testHUDRendersVikReplyAtCompactAndExpandedSizes() async throws {
        let h = VikHarness()
        defer { h.assistant.shutdown() }
        h.send("Эй Алёна с чего начать поиск клиентов?")
        await waitUntil { h.reply != nil }
        h.reply?.yield("Начни с двух знакомых клиентов: спроси, кому сейчас нужна твоя помощь. Это первый шаг на понедельник [D2].")
        h.reply?.finish()
        await waitUntil { h.assistant.savedReply != nil }
        h.voice.onStarted?()
        for size in [CGSize(width: 360, height: 220), CGSize(width: 600, height: 320), CGSize(width: 360, height: 70)] {
            let view = ResponsiveHUDView(capture: CaptureSession(), recentNotes: RecentNotes(limit: 3),
                                         onOpenDocument: {}, vik: h.assistant)
            let host = NSHostingController(rootView: view)
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.setContentSize(size)
            window.orderFrontRegardless()
            for _ in 0..<4 { try await Task.sleep(for: .milliseconds(50)) }
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 2_000)
            if let dir = ProcessInfo.processInfo.environment["WIMM_SNAPSHOT_DIR"] {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("vik-hud-\(Int(size.width))x\(Int(size.height)).png"))
            }
            window.orderOut(nil)
        }
    }
}

@MainActor
private final class VikHarness {
    let capture = VikTestCapture()
    let voice = VikTestVoice()
    var assistant: VikAssistant!
    var privateMode = false
    var calls: [(query: String, note: String, tools: [String])] = []
    var reply: AsyncThrowingStream<String, Error>.Continuation?
    var opened: [URL] = []

    init(document: String = "", timeout: Duration = .seconds(20)) {
        assistant = VikAssistant(capture: capture, voice: voice, document: { document },
                                 isPrivate: { [weak self] in self?.privateMode ?? true },
                                 finalizationTimeout: timeout,
                                 openCodeTask: { [weak self] in self?.opened.append($0); return true },
                                 stream: { [weak self] query, note, tools in
            self?.calls.append((query, note, tools.map(\.name)))
            return AsyncThrowingStream { self?.reply = $0 }
        })
        capture.onAction = { [weak self] in self?.assistant.captureWillAct($0) }
        capture.onSendRequested = { [weak self] in self?.assistant.silenceDetected() ?? false }
        capture.onFinal = { [weak self] file, revision, result in
            self?.assistant.liveFinalized(file, revision: revision, result: result)
        }
    }

    func send(_ text: String = "Эй Алёна ответь") {
        capture.liveText = text
        assistant.tick()
        assistant.sendNow()
    }
}

@MainActor
private final class VikTestCapture: VikCapturing {
    var isRecording = true
    var isBusy = false
    var isSending = false
    var actionRevision: UInt64 = 1
    var recordingURL: URL? = StoragePaths.baseDirectory().appendingPathComponent("\(UUID().uuidString).aac")
    var liveText = ""
    var quietAfterSpeech: (seconds: Double, revision: UInt64)?
    var starts = 0, stops = 0
    var holdFinal = false
    var onAction: ((CaptureSession.UserAction) -> Void)?
    var onFinal: ((URL, UInt64, Result<String, Error>) -> Void)?
    var onSendRequested: (() -> Bool)?
    var beforeMicrophone: (() -> Void)?
    private var pending: (URL, UInt64)?

    func userStart() {
        actionRevision += 1
        onAction?(.start)
        beforeMicrophone?()
        isRecording = true; liveText = ""
        recordingURL = StoragePaths.baseDirectory().appendingPathComponent("\(UUID().uuidString).aac")
    }

    func userStop() {
        actionRevision += 1
        onAction?(.stop)
        close()
    }

    func send() async {
        if onSendRequested?() == true { return }
        actionRevision += 1
        onAction?(.send)
        roll()
    }

    /// The note rolls over; the microphone stays open.
    func roll() {
        guard isRecording, let file = recordingURL else { return }
        pending = (file, actionRevision)
        let text = liveText
        liveText = ""
        recordingURL = StoragePaths.baseDirectory().appendingPathComponent("\(UUID().uuidString).aac")
        if !holdFinal { finish(.success(text)) }
    }

    func start(ifUnchangedSince revision: UInt64) async {
        guard actionRevision == revision, !isRecording, !isBusy else { return }
        actionRevision += 1; starts += 1
        beforeMicrophone?()
        isRecording = true; liveText = ""
        recordingURL = StoragePaths.baseDirectory().appendingPathComponent("\(UUID().uuidString).aac")
    }

    func stop(ifUnchangedSince revision: UInt64, recordingURL file: URL, silenceRevision: UInt64?) async -> Bool {
        guard actionRevision == revision, recordingURL == file, isRecording else { return false }
        stops += 1
        close()
        return true
    }

    private func close() {
        guard isRecording, let file = recordingURL else { return }
        isRecording = false
        pending = (file, actionRevision)
        if !holdFinal { finish(.success(liveText)) }
    }

    func finish(_ result: Result<String, Error>) {
        guard let (file, revision) = pending else { return }
        pending = nil
        onFinal?(file, revision, result)
    }
}

@MainActor
private final class VikTestVoice: VikVoicePlaying {
    var onIdle: (() -> Void)?
    var onStarted: (() -> Void)?
    var onFailure: (() -> Void)?
    var lines: [String] = []
    var prepares = 0
    var isPlaying = false
    func prepare() { prepares += 1 }
    func enqueue(_ text: String) { lines.append(text) }
    func stop() { isPlaying = false }
}

extension VikAssistantTests {
    func testRealCaptureFinalTextWithoutAddressFailsInsteadOfWaiting() async throws {
        let live = VikHeldASR()
        let capture = CaptureSession(sourceFactory: { VikNoMicrophone() }, liveFactory: { live })
        capture.allowsNoteCardAnalysis = false
        let assistant = VikAssistant(capture: capture, voice: VikTestVoice(), isPrivate: { false },
                                     stream: { _, _, _ in AsyncThrowingStream { $0.finish() } })
        capture.onUserAction = { assistant.captureWillAct($0) }
        capture.onLiveFinalized = { assistant.liveFinalized($0, revision: $1, result: $2) }
        defer {
            assistant.shutdown()
            capture.onUserAction = nil
            capture.onLiveFinalized = nil
            capture.finishForTermination()
        }
        await capture.start()
        await waitUntil { capture.liveText.contains("Эй Алёна") }
        await live.completeImmediately("Эвалёна торчас. Мелёна, который час?")
        assistant.tick()
        assistant.sendNow()
        await waitUntil { capture.phase == .idle }
        await waitUntil { assistant.phase != .finishing }
        XCTAssertEqual(assistant.phase, .failed)
    }

    func testRealCaptureWaitsForHeldFinalASRBeforeModelReceivesWholeNote() async throws {
        let live = VikHeldASR()
        let capture = CaptureSession(sourceFactory: { VikNoMicrophone() }, liveFactory: { live })
        capture.allowsNoteCardAnalysis = false
        let voice = VikTestVoice()
        var received: String?
        let assistant = VikAssistant(capture: capture, voice: voice, isPrivate: { false },
                                     stream: { query, note, _ in
            XCTAssertEqual(query, "полный вопрос с последней фразой?")
            received = note
            return AsyncThrowingStream { $0.yield("Ответ."); $0.finish() }
        })
        capture.onUserAction = { assistant.captureWillAct($0) }
        capture.onLiveFinalized = { assistant.liveFinalized($0, revision: $1, result: $2) }
        defer {
            assistant.shutdown()
            capture.onUserAction = nil
            capture.onLiveFinalized = nil
            capture.finishForTermination()
        }
        await capture.start()
        await waitUntil { capture.liveText.contains("Эй Алёна") }
        assistant.tick()
        assistant.sendNow()
        await waitUntil { capture.phase == .idle }
        for _ in 0..<200 {
            if await live.isFinishing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(received)
        XCTAssertEqual(assistant.phase, .finishing)
        await live.complete("Объяснение идеи до обращения. Эй Алёна полный вопрос с последней фразой?")
        await waitUntil { received != nil }
        XCTAssertTrue(received?.hasPrefix("Объяснение идеи до обращения.") == true)
        await waitUntil { assistant.savedReply != nil }
        XCTAssertFalse(capture.isRecording)
        assistant.cancel()
        voice.onIdle?()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(capture.isRecording)
    }
}

private struct VikNoMicrophone: LiveAudioSource {
    func requestAccess() async throws {}
    func start(bufferHandler: @escaping LiveAudioBufferHandler,
               completionHandler: @escaping LiveAudioCompletionHandler) throws -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    }
    func stop() {}
}

private actor VikHeldASR: CaptureLiveTranscribing {
    private var completion: CheckedContinuation<String, Error>?
    var isFinishing: Bool { completion != nil }
    func prepare() async throws {}
    func append(_ samples: [Float]) {}
    func refresh() async throws -> String? { "Эй Алёна неполный вопрос" }
    private var immediate: String?
    func completeImmediately(_ text: String) { immediate = text }
    func finish() async throws -> String {
        if let immediate { return immediate }
        return try await withCheckedThrowingContinuation { completion = $0 }
    }
    func complete(_ text: String) {
        completion?.resume(returning: text)
        completion = nil
    }
}
