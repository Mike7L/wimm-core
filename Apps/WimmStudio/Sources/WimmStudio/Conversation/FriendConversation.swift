@preconcurrency import AVFoundation
import Foundation
import Observation
import WimmDomain
import WimmInfrastructure

/// The "Друг" window's side of the `wimm-conversation` skill. The agent
/// talks in its own chat and writes each reply to `replyURL`; this model
/// picks the file up, shows it large and reads it aloud. The user's answers
/// are ordinary Wimm recordings (the shared `CaptureSession`), which the
/// skill finds through `recent_notes` after "записал".
///
/// In the angel-and-demon mode the window runs the conversation itself:
/// `ShouldersChat` streams each turn and every line is spoken the moment
/// it is complete, and the user's answers go to it instead of `answerURL`.
@MainActor @Observable
final class FriendConversation: NSObject {
    /// Where the agent writes its current reply (plain text or light Markdown).
    nonisolated static var replyURL: URL {
        StoragePaths.baseDirectory()
            .appendingPathComponent("Conversation", isDirectory: true)
            .appendingPathComponent("friend.md")
    }

    /// Where this window puts each finished answer, for the agent waiting on it.
    nonisolated static var answerURL: URL {
        replyURL.deletingLastPathComponent().appendingPathComponent("answer.json")
    }

    private(set) var reply = ""
    /// The reply as an angel-and-demon dialogue, nil for an ordinary one.
    private(set) var dialogue: [ShoulderLine]?
    private(set) var receivedAt: Date?
    private(set) var isSpeaking = false
    /// The dialogue line being read aloud.
    private(set) var speakingLine: Int?
    /// The user finished a recording and no reply has arrived since.
    private(set) var awaitingReply = false
    /// The document the angel and demon talk about; nil in the ordinary "Друг" mode.
    private(set) var shouldersDocument: URL?
    /// What the angel-and-demon mode is busy with ("Читают документ…"), shown in the status.
    private(set) var shouldersActivity: String?
    private(set) var shouldersError: String?
    var speaksAloud: Bool {
        didSet {
            UserDefaults.standard.set(speaksAloud, forKey: Self.speaksKey)
            if !speaksAloud { stopSpeaking() }
        }
    }

    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// Supertonic-3 voices for the dialogue; the system voice reads until they are loaded.
    @ObservationIgnored private let neuralVoices = ShoulderVoicePlayer()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var lastModified: Date?
    @ObservationIgnored private var utteranceLines: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var shoulders: ShouldersChat?
    @ObservationIgnored private var turnTask: Task<Void, Never>?
    @ObservationIgnored private var turnSerial = 0
    /// When the user stopped the last recording, for the latency log.
    @ObservationIgnored private var answerStoppedAt: Date?
    /// The current turn's lines are already in the conversation history.
    @ObservationIgnored private var turnRecorded = true
    private static let speaksKey = "WimmStudio.friendSpeaksAloud"

    override init() {
        speaksAloud = UserDefaults.standard.object(forKey: Self.speaksKey) as? Bool ?? true
        super.init()
        synthesizer.delegate = self
        neuralVoices.onLineStarted = { [weak self] in self?.speakingLine = $0 }
        neuralVoices.onIdle = { [weak self] in
            self?.isSpeaking = false
            self?.speakingLine = nil
        }
    }

    /// Shows the reply already on disk without speaking it, then watches for new ones.
    func start() {
        guard poll == nil else { return }
        // The first load in a fresh app compiles for the Neural Engine (~1 min): start it with the window.
        neuralVoices.prepare()
        try? FileManager.default.createDirectory(at: Self.replyURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        load(speak: false)
        // Polling the date survives the agent's atomic save (a new inode), unlike a file watcher.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.load(speak: true)
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
        closeTurn()
        stopSpeaking()
    }

    /// Stops the voice and any turn still being written: the user is about to speak.
    func interrupt() {
        closeTurn()
        stopSpeaking()
    }

    // MARK: - Angel and demon

    /// Switches the window to the built-in angel-and-demon conversation about
    /// `document`. Asking again after a failure, or after picking another style, starts over.
    func startShoulders(document: URL?) {
        guard let document else {
            shouldersError = "Открой личный документ в Studio — Ангелу и Демону нужно, о чём говорить."
            return
        }
        guard document != shouldersDocument || shouldersError != nil || shoulders?.style != ShouldersStyle.current else { return }
        interrupt()
        shouldersDocument = document
        dialogue = []
        reply = ""
        shoulders = ShouldersChat(document: document)
        neuralVoices.prepare()
        runTurn(answer: nil)
    }

    /// Back to the ordinary "Друг" window fed by the agent's `friend.md`.
    func stopShoulders() {
        guard shoulders != nil else { return }
        interrupt()
        shoulders = nil
        shouldersDocument = nil
        shouldersActivity = nil
        shouldersError = nil
        lastModified = nil
        reply = ""
        dialogue = nil
        load(speak: false)
    }

    private func runTurn(answer: String?) {
        closeTurn()
        guard let shoulders else { return }
        shouldersError = nil
        shouldersActivity = shoulders.isPrepared ? "Думают…" : "Читают документ…"
        turnSerial += 1
        let serial = turnSerial
        let asked = Date(), stopped = answer == nil ? nil : answerStoppedAt
        turnTask = Task { [weak self] in
            // A turn replaced by a newer one must not touch the window any more.
            @MainActor func isCurrent() -> Bool { self?.turnSerial == serial && !Task.isCancelled }
            var first = true
            do {
                // An answer recorded while the document is still being read waits for it.
                try await shoulders.prepare()
                guard isCurrent() else { return }
                self?.shouldersActivity = "Думают…"
                for try await line in shoulders.turn(answer: answer) {
                    guard isCurrent(), let self else { return }
                    if first {
                        first = false
                        self.beginTurn()
                        // The wait the user hears: recording stopped → transcript → first line.
                        let transcript = stopped.map { String(format: " (stop→text %.1fs)", asked.timeIntervalSince($0)) } ?? ""
                        log(String(format: "[Shoulders] first line after %.1fs%@", Date().timeIntervalSince(asked), transcript))
                    }
                    self.receive(line)
                }
                guard isCurrent() else { return }
                self?.shouldersActivity = nil
                self?.closeTurn()
            } catch {
                guard isCurrent() else { return }
                self?.turnFailed(error)
            }
        }
    }

    /// Ends the turn in flight and hands what was said so far to the conversation.
    private func closeTurn() {
        turnTask?.cancel()
        turnTask = nil
        if !turnRecorded, let dialogue { shoulders?.heard(dialogue) }
        turnRecorded = true
    }

    private func beginTurn() {
        stopSpeaking()
        dialogue = []
        reply = ""
        receivedAt = Date()
        awaitingReply = false
        shouldersActivity = nil
        turnRecorded = false
    }

    private func receive(_ line: ShoulderLine) {
        var lines = dialogue ?? []
        lines.append(line)
        dialogue = lines
        reply = lines.map { "\($0.speaker.emoji): \($0.text)" }.joined(separator: "\n")
        guard speaksAloud else { return }
        isSpeaking = true
        enqueue(line, index: lines.count - 1)
    }

    private func turnFailed(_ error: Error) {
        guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
        shouldersActivity = nil
        awaitingReply = false
        shouldersError = PrivateMode.isRefusal(error)
            ? "Приватный режим: разговор с Ангелом и Демоном не уходит в облако."
            : "Ангел и Демон не ответили: \(error.localizedDescription)"
        log("[Shoulders] turn failed: \(error.localizedDescription)")
    }

    func answerRecorded() {
        answerStoppedAt = Date()
        awaitingReply = true
        shouldersError = nil
    }

    /// A recording made while the window is open has its final text: hand it
    /// to the agent, which waits for this file instead of a "записал" in chat.
    func answerTranscribed(_ note: URL, text: String) {
        guard poll != nil else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let shoulders {
            if trimmed.isEmpty {
                awaitingReply = false
                shouldersError = "Не расслышали — запиши ещё раз."
            } else {
                let prompt = shoulders.placementContext(currentReply: reply)
                try? RecallSidecar.linkConversation(
                    forRecordingURL: note,
                    source: "shoulders-conversation",
                    doc: shouldersDocument?.lastPathComponent,
                    conversationId: shoulders.conversationId,
                    conversationFile: shoulders.conversationRelativeFile,
                    prompt: prompt
                )
                shoulders.persistTranscript(latestNoteName: note.lastPathComponent, latestAnswerText: trimmed)
                runTurn(answer: trimmed)
            }
            return
        }
        if !trimmed.isEmpty {
            try? RecallSidecar.linkConversation(
                forRecordingURL: note,
                source: "friend-conversation",
                conversationFile: "Conversation/friend.md",
                prompt: reply
            )
        }
        let answer: [String: Any] = [
            "note": note.lastPathComponent,
            "path": note.path,
            "finished_at": ISO8601DateFormatter().string(from: Date()),
            "text": text,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.answerURL, options: .atomic)
        } catch {
            log("[Friend] answer not written: \(error.localizedDescription)")
        }
    }

    func replay() {
        speak(reply)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        neuralVoices.stop()
        isSpeaking = false
        speakingLine = nil
        utteranceLines = [:]
    }

    private func load(speak shouldSpeak: Bool) {
        // The built-in conversation owns the window; the agent's file waits.
        guard shoulders == nil else { return }
        let url = Self.replyURL
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified != lastModified,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        lastModified = modified
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != reply else { return }
        reply = trimmed
        dialogue = ShouldersDialogue.lines(trimmed)
        receivedAt = modified
        awaitingReply = false
        if shouldSpeak { speak(trimmed) }
    }

    private func speak(_ markdown: String) {
        guard speaksAloud, !markdown.isEmpty else { return }
        stopSpeaking()
        isSpeaking = true
        guard let lines = ShouldersDialogue.lines(markdown) else {
            let utterance = AVSpeechUtterance(string: Self.plainText(markdown))
            utterance.voice = Self.voice
            utteranceLines[ObjectIdentifier(utterance)] = Self.notALine
            synthesizer.speak(utterance)
            return
        }
        neuralVoices.prepare()
        // The synthesizer queues the lines; didStart tells which one is playing.
        for (index, line) in lines.enumerated() {
            enqueue(line, index: index)
        }
    }

    private func enqueue(_ line: ShoulderLine, index: Int) {
        // A turn the system voice already started reading stays with it.
        if neuralVoices.isReady && utteranceLines.isEmpty {
            neuralVoices.enqueue(Self.plainText(line.text), speaker: line.speaker, index: index)
            return
        }
        if index == 0 { log("[ShoulderVoice] turn read by the system voice (Supertonic-3 not ready)") }
        let utterance = AVSpeechUtterance(string: Self.plainText(line.text))
        utterance.voice = line.speaker.voice
        utterance.pitchMultiplier = line.speaker.pitch
        utterance.rate = line.speaker.rate
        utterance.postUtteranceDelay = 0.08
        utteranceLines[ObjectIdentifier(utterance)] = index
        synthesizer.speak(utterance)
    }

    /// Marks an ordinary "Друг" reply in `utteranceLines`: it is spoken but has no dialogue line.
    private static let notALine = -1

    /// An utterance ended; with none left the window stops showing the voice.
    /// `synthesizer.isSpeaking` is still true inside `didFinish`, so it cannot tell.
    private func utteranceEnded(_ id: ObjectIdentifier) {
        guard utteranceLines.removeValue(forKey: id) != nil, utteranceLines.isEmpty else { return }
        isSpeaking = false
        speakingLine = nil
    }

    /// The best installed voice for the reply's language: Russian first, enhanced over default.
    private static let voice: AVSpeechSynthesisVoice? = {
        let russian = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ru") }
        return russian.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }()

    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private static func plainText(_ markdown: String) -> String {
        String(attributed(markdown).characters)
            .replacingOccurrences(of: "#", with: "")
    }
}

extension FriendConversation: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let line = self.utteranceLines[id], line != Self.notALine { self.speakingLine = line }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.utteranceEnded(id) }
    }
}
