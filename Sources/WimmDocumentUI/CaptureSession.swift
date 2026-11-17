@preconcurrency import AVFoundation
import Foundation
import Observation
import os
import WimmDomain
import WimmInfrastructure

/// A place in the document the owner pointed at while speaking. Speech from
/// this click to the next one (or to Stop) becomes a comment on it.
public struct VoiceAnchor: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable { case listening, transcribing, posted(String), empty, failed(String) }
    public let id = UUID()
    public let target: CommentTarget
    public let startSample: Int
    public var endSample: Int?
    public var state: State = .listening
}

/// What a comment points at: the document, its section and the quote.
public struct CommentTarget: Equatable, Sendable {
    public init(documentURL: URL, section: String?, heading: String?, selector: TextQuoteSelector) {
        self.documentURL = documentURL; self.section = section; self.heading = heading; self.selector = selector
    }
    public let documentURL: URL
    public let section: String?
    public let heading: String?
    public let selector: TextQuoteSelector
}

protocol CaptureLiveTranscribing: Actor {
    func prepare() async throws
    func append(_ samples: [Float]) async
    func refresh() async throws -> String?
    func finish() async throws -> String
}

extension ParakeetLiveTranscriber: CaptureLiveTranscribing {}

/// One recording: microphone → AAC/ADTS in the library + live Parakeet text,
/// plus spoken comments cut at the document clicks made while it runs.
///
/// The note it writes is an ordinary library note: `RecordingIdentity`
/// sidecar before capture, and the live text stored the way the iPhone
/// recorder's is promoted (`transcript` == `localTranscript`), so a later
/// file run in Wimm archives it correctly as the realtime copy.
@MainActor @Observable
public final class CaptureSession {
    public convenience init() {
        self.init(sourceFactory: { MicrophoneAudioSource() },
                  liveFactory: { ParakeetLiveTranscriber() },
                  speechFactory: { SpeechDetector() })
    }

    init(sourceFactory: @escaping () -> any LiveAudioSource,
         liveFactory: @escaping () -> any CaptureLiveTranscribing,
         speechFactory: @escaping () -> (any SpeechDetecting)? = { nil }) {
        self.sourceFactory = sourceFactory
        self.liveFactory = liveFactory
        self.speechFactory = speechFactory
    }

    @ObservationIgnored private let speechFactory: () -> (any SpeechDetecting)?
    @ObservationIgnored private var speech: (any SpeechDetecting)?

    @ObservationIgnored private let sourceFactory: () -> any LiveAudioSource
    @ObservationIgnored private let liveFactory: () -> any CaptureLiveTranscribing
    public enum Phase: Equatable { case idle, starting, recording, finishing }

    public private(set) var phase: Phase = .idle
    public private(set) var startedAt: Date?
    public private(set) var liveText = ""
    public private(set) var level: Float = 0
    /// The microphone hears speech, not just sound. Indicator only.
    public private(set) var isSpeech = false
    /// Quiet after speech that is about to send the note; nil while none is pending.
    public private(set) var pendingSend: PendingSend?
    /// Recording is on but the input delivers nothing (digital silence or a stopped source).
    public private(set) var inputTrouble = false
    /// Grows by one each time a note is sent and the next one starts.
    public private(set) var sendCount: UInt64 = 0
    public struct PendingSend: Equatable, Sendable {
        public var quietSeconds: Double
        public var totalSeconds: Double
    }
    public private(set) var anchors: [VoiceAnchor] = []
    public private(set) var recordingURL: URL?
    /// Every explicit capture command invalidates an older automation's lease,
    /// even when that command cannot run in the current phase.
    public private(set) var actionRevision: UInt64 = 0
    public enum UserAction { case start, stop, send }
    @ObservationIgnored public var onUserAction: (@MainActor (UserAction) -> Void)?
    /// Actual microphone lifecycle, excluding note rollovers and failed starts.
    @ObservationIgnored public var onRecordingChanged: (@MainActor (Bool) -> Void)?
    /// Returning true consumes this existing silence event (the host closes
    /// the note instead of rolling it over). No second silence detector.
    @ObservationIgnored public var onSilenceDetected: (@MainActor (UInt64) -> Bool)?
    @ObservationIgnored public var onSendRequested: (@MainActor () -> Bool)?
    @ObservationIgnored public var onLiveFinalized: (@MainActor (URL, UInt64, Result<String, Error>) -> Void)?
    public var errorMessage: String?

    /// Called after a spoken comment was appended to a threads file.
    @ObservationIgnored public var onCommentPosted: (@MainActor (URL) -> Void)?
    /// Called after a recording became a note.
    @ObservationIgnored public var onNoteSaved: (@MainActor (URL) -> Void)?
    /// Called for every finished recording: the app owes it an on-device file
    /// run (the "local" text), whether or not live text came.
    @ObservationIgnored public var onTranscriptMissing: (@MainActor (URL) -> Void)?
    /// Called once a finished recording has its final live text (empty when nothing was heard).
    @ObservationIgnored public var allowsNoteCardAnalysis = true
    @ObservationIgnored public var onNoteTranscribed: (@MainActor (URL, String) -> Void)?

    @ObservationIgnored private var source: (any LiveAudioSource)?
    @ObservationIgnored private var gate: SilenceGate?
    @ObservationIgnored private var gateLoop: Task<Void, Never>?
    @ObservationIgnored private var format: AVAudioFormat?
    @ObservationIgnored private var live: (any CaptureLiveTranscribing)?
    @ObservationIgnored private var store = SampleStore()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var levelLoop: Task<Void, Never>?
    @ObservationIgnored private let reader = ParakeetTranscriptionAdapter()
    @ObservationIgnored private let levelMeter = LevelMeter()

    public var isRecording: Bool { phase == .recording }
    /// Quiet in the current note since its last speech (nil before any speech).
    public var quietAfterSpeech: (seconds: Double, revision: UInt64)? { gate?.quietAfterSpeech() }
    public var isBusy: Bool { phase == .starting || phase == .finishing }

    public func toggle() {
        guard phase == .idle || phase == .recording else { return }
        let starting = phase == .idle
        actionRevision &+= 1
        onUserAction?(starting ? .start : .stop)
        let revision = actionRevision
        // Revoke automation at the click, before the scheduled task can race
        // with an already queued automatic resume.
        Task {
            guard actionRevision == revision else { return }
            if starting { await startRecording() }
            else { await stopRecording() }
        }
    }

    public func start() async {
        actionRevision &+= 1
        onUserAction?(.start)
        await startRecording()
    }

    public func start(ifUnchangedSince revision: UInt64) async {
        guard actionRevision == revision, phase == .idle else { return }
        actionRevision &+= 1
        await startRecording()
    }

    private func startRecording() async {
        guard phase == .idle else { return }
        let revision = actionRevision
        phase = .starting
        errorMessage = nil
        liveText = ""
        anchors = []
        store = SampleStore()
        let identity = RecordingIdentity()
        do {
            try FileStore.ensureDirectoryExists()
            try FileManager.default.createDirectory(at: FileStore.recordingsDirectory(), withIntermediateDirectories: true)
            let url = FileStore.newRecordingURL(identity: identity, extension: AudioFileSink.fileExtension)
            identity.persist(for: url)
            let source = sourceFactory()
            try await source.requestAccess()
            guard actionRevision == revision else {
                phase = .idle
                return
            }
            self.source = source
            speech = speechFactory()
            let gate = SilenceGate(policy: SilenceSplitPolicy.stored(), store: store, speech: speech)
            self.gate = gate
            let format = try await startAudioRetrying(source, revision: revision)
            gate.start(with: try AudioFileSink(url: url, format: format))
            self.format = format
            recordingURL = url
            startedAt = Date()
            phase = .recording
            stampInputDevice()
            startLive()
            startLevel()
            startGateLoop(gate)
            onRecordingChanged?(true)
        } catch {
            source?.stop()
            source = nil
            gate?.finish()
            gate = nil
            gateLoop?.cancel()
            gateLoop = nil
            speech = nil
            phase = .idle
            if case CaptureSessionError.superseded? = error as? CaptureSessionError { return }
            errorMessage = Self.microphoneMessage(for: error, device: inputDeviceName)
        }
    }

    /// A Bluetooth headset switching profile rejects the input format for a
    /// moment ('!dat', or a sample-rate mismatch), so a failed microphone start
    /// is retried this long before it is reported.
    @ObservationIgnored var microphoneRetryWindow: Duration = .seconds(3)
    static let microphoneRetryInterval: Duration = .milliseconds(250)

    /// Starts `first`, or a fresh source after each failure, until one runs or
    /// the retry window ends. Stops early when another capture command came in.
    private func startAudioRetrying(_ first: any LiveAudioSource, revision: UInt64) async throws -> AVAudioFormat {
        let clock = ContinuousClock()
        let deadline = clock.now + microphoneRetryWindow
        var source = first
        var attempt = 1
        while true {
            do {
                let format = try startAudio(source)
                self.source = source
                if attempt > 1 { log("[Capture] \(inputDeviceName ?? "input") started on attempt \(attempt)") }
                return format
            } catch {
                source.stop()
                let device = (source as? MicrophoneAudioSource)?.inputDevice?.name ?? "unknown input"
                log("[Capture] \(device) failed to start (attempt \(attempt)): \(Self.describe(error))")
                guard clock.now < deadline else { throw error }
                try? await Task.sleep(for: Self.microphoneRetryInterval)
                guard actionRevision == revision else { throw CaptureSessionError.superseded }
                source = sourceFactory()
                self.source = source
                attempt += 1
            }
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code)\(fourCC(ns.code).map { " '\($0)'" } ?? ""): \(ns.localizedDescription)"
    }

    static func fourCC(_ code: Int) -> String? {
        guard code > 0x2020_2020, code <= 0x7E7E_7E7E else { return nil }
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The input refused its format ('!dat' from CoreAudio, or our own
    /// sample-rate check): what a Bluetooth profile switch looks like.
    static func isFormatRefusal(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.code == 0x2164_6174 || (ns.domain == "MicrophoneAudioSource" && ns.code == 2003)
    }

    static func microphoneMessage(for error: Error, device: String?) -> String {
        guard isFormatRefusal(error) else { return error.localizedDescription }
        let name = device.map { "«\($0)»" } ?? ""
        return "Микрофон \(name) не принял формат записи — наушники, вероятно, переключали режим. Нажмите запись ещё раз или выберите другой вход."
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func clearSignals() {
        speech = nil
        isSpeech = false
        pendingSend = nil
        inputTrouble = false
    }

    private func refreshSignals() {
        let speaking = speech?.isSpeech ?? false
        if isSpeech != speaking { isSpeech = speaking }
        let pending = gate?.pendingSend().map { PendingSend(quietSeconds: $0.quiet, totalSeconds: $0.total) }
        if pendingSend != pending { pendingSend = pending }
        if inputTrouble, levelMeter.hasSignal { inputTrouble = false }
    }

    public func stop() async {
        actionRevision &+= 1
        onUserAction?(.stop)
        await stopRecording()
    }

    @discardableResult
    public func stop(ifUnchangedSince revision: UInt64, recordingURL url: URL,
                     silenceRevision: UInt64? = nil) async -> Bool {
        guard actionRevision == revision, recordingURL == url, phase == .recording, !isSending else { return false }
        if let silenceRevision, gate?.isCurrentSilence(silenceRevision) != true { return false }
        await stopRecording()
        return true
    }

    private func stopRecording() async {
        guard phase == .recording else { return }
        let revision = actionRevision
        phase = .finishing
        source?.stop()
        source = nil
        // A silence send may already be on the main actor. Let it swap files, then close whatever note is current.
        gate?.endEvents()
        await gateLoop?.value
        gateLoop = nil
        gate?.finish()?.finish()
        gate = nil
        format = nil
        onRecordingChanged?(false)
        let oldLoop = loop
        oldLoop?.cancel()
        loop = nil
        levelLoop?.cancel()
        levelLoop = nil
        clearSignals()
        guard let url = recordingURL else {
            level = 0
            startedAt = nil
            phase = .idle
            return
        }
        closeOpenAnchor()
        let oldLive = live
        live = nil
        let tail = store.takeForLive()
        finalizeNoteInBackground(url: url, live: oldLive, loop: oldLoop,
                                 tail: tail, fallbackText: liveText, revision: revision)
        // Only closing the audio file belongs to the capture lifecycle. ASR and
        // analysis keep their own snapshot and cannot hold the microphone busy.
        level = 0
        startedAt = nil
        phase = .idle
        onNoteSaved?(url)
    }

    /// Close the audio synchronously. The next launch can transcribe the full file.
    public func finishForTermination() {
        actionRevision &+= 1
        onUserAction?(.stop)
        guard phase == .recording else { return }
        phase = .finishing
        closeAudio()
        onRecordingChanged?(false)
        loop?.cancel()
        levelLoop?.cancel()
    }

    private func startAudio(_ source: any LiveAudioSource) throws -> AVAudioFormat {
        guard let gate else { throw CaptureSessionError.missingGate }
        let meter = levelMeter
        return try source.start(bufferHandler: { buffer in
            meter.update(buffer)
            gate.process(buffer)
        }, completionHandler: { _ in })
    }

    private func closeAudio() {
        source?.stop()
        source = nil
        gate?.finish()?.finish()
        gate = nil
        gateLoop?.cancel()
        gateLoop = nil
        format = nil
    }

    /// True while `send()` is handing the microphone over to the next note.
    public private(set) var isSending = false

    /// Finishes the current note and keeps recording into a new one: the
    /// microphone never stops, only the file and the live text roll over.
    public func send() async {
        if onSendRequested?() == true { return }
        actionRevision &+= 1
        onUserAction?(.send)
        await sendRecording()
    }

    private func sendRecording() async {
        guard phase == .recording, !isSending, gate != nil, let oldURL = recordingURL, let format else { return }
        isSending = true
        defer { isSending = false }
        closeOpenAnchor()

        let identity = RecordingIdentity()
        let newURL = FileStore.newRecordingURL(identity: identity, extension: AudioFileSink.fileExtension)
        identity.persist(for: newURL)
        let newSink: AudioFileSink
        do {
            newSink = try AudioFileSink(url: newURL, format: format)
        } catch {
            try? FileManager.default.removeItem(at: FileStore.metadataURL(forRecordingURL: newURL))
            errorMessage = error.localizedDescription
            return
        }
        // Swap first, then drain: speech after this point belongs to the new note.
        gate?.swap(to: newSink)?.finish()
        sendCount &+= 1
        recordingURL = newURL
        stampInputDevice()
        let oldLoop = loop
        oldLoop?.cancel()
        loop = nil
        let tail = store.takeForLive()
        let oldLive = live
        live = nil
        let previousText = liveText
        liveText = ""
        startedAt = Date()
        startLive()
        finalizeNoteInBackground(url: oldURL, live: oldLive, loop: oldLoop,
                                 tail: tail, fallbackText: previousText, revision: actionRevision)
        onNoteSaved?(oldURL)
    }

    /// Quiet after speech sends the note the same way the Send button does.
    private func startGateLoop(_ gate: SilenceGate) {
        gateLoop = Task { [weak self] in
            for await revision in gate.events {
                guard let self else { return }
                guard gate.isCurrentSilence(revision) else { continue }
                if self.onSilenceDetected?(revision) != true { await self.sendRecording() }
            }
        }
    }

    private func finalizeNoteInBackground(
        url: URL, live: (any CaptureLiveTranscribing)?, loop: Task<Void, Never>?,
        tail: [Float], fallbackText: String, revision: UInt64
    ) {
        // Preserve the text already heard even if the final read fails or the
        // app quits before it completes. Audio is already durable at this point.
        Self.storeLiveText(fallbackText, for: url)
        Task { [weak self] in
            // An in-flight refresh must finish before the final read of this
            // transcriber's tail. Neither task can consume the next note's store.
            await loop?.value
            var text = fallbackText
            var finalResult: Result<String, Error> = .failure(CaptureSessionError.liveUnavailable)
            if let live {
                await live.append(tail)
                do {
                    text = try await live.finish()
                    finalResult = .success(text)
                } catch {
                    finalResult = .failure(error)
                    log("[Capture] Parakeet final read failed for \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            Self.storeLiveText(text, for: url)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("[Capture] \(url.lastPathComponent) has no live text")
            }
            // Live text is the realtime source; the on-device file run is the local one.
            // Both are wanted for every note, so the host is told even when live text exists.
            self?.onTranscriptMissing?(url)
            // A late result may update the stopped note, never a new recording.
            if let self, self.phase == .idle, self.recordingURL == url {
                self.liveText = text
            }
            self?.onNoteSaved?(url)
            self?.onLiveFinalized?(url, revision, finalResult)
            self?.onNoteTranscribed?(url, text)
            if self?.allowsNoteCardAnalysis == true, ProcessingCfg.noteCardEnabled {
                Task.detached {
                    _ = try? await NoteProcessor.shared.process(file: url)
                }
            }
        }
    }

    // MARK: - Spoken comments

    /// The owner pointed at `target` while recording: the previous anchor's
    /// speech ends here and a new one starts.
    public func point(at target: CommentTarget) {
        guard phase == .recording else { return }
        if let last = anchors.last, last.state == .listening, last.target == target { return }
        closeOpenAnchor()
        anchors.append(VoiceAnchor(target: target, startSample: store.total))
    }

    /// The anchor still collecting speech, if any.
    public var listeningAnchor: VoiceAnchor? { anchors.last.flatMap { $0.state == .listening ? $0 : nil } }

    private func closeOpenAnchor() {
        guard let index = anchors.indices.last, anchors[index].state == .listening else { return }
        let end = store.total
        anchors[index].endSample = end
        anchors[index].state = .transcribing
        let anchor = anchors[index]
        let samples = store.slice(from: anchor.startSample, to: end)
        store.release(before: end)
        let reader = self.reader, note = recordingURL
        Task {
            let state: VoiceAnchor.State
            do {
                let text = samples.count < 8_000 ? "" : try await Self.read(samples, with: reader)
                if text.isEmpty {
                    state = .empty
                } else {
                    try await Self.post(text, anchor: anchor, note: note)
                    state = .posted(text)
                }
            } catch { state = .failed(error.localizedDescription) }
            if let i = anchors.firstIndex(where: { $0.id == anchor.id }) { anchors[i].state = state }
            if case .posted = state { onCommentPosted?(anchor.target.documentURL) }
        }
    }

    private nonisolated static func read(_ samples: [Float], with reader: ParakeetTranscriptionAdapter) async throws -> String {
        let result = try await reader.transcribe(samples: samples)
        return result.looksLikeSilence ? "" : result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func post(_ text: String, anchor: VoiceAnchor, note: URL?) async throws {
        let store = DocumentCommentStore(document: anchor.target.documentURL)
        var via: String?
        if let note {
            let sidecar = StoragePaths.relativePath(for: FileStore.metadataURL(forRecordingURL: note))
            let from = SampleStore.seconds(anchor.startSample), to = SampleStore.seconds(anchor.endSample ?? anchor.startSample)
            via = String(format: "voice:%@#t=%.1f-%.1f", sidecar, from, to)
        }
        let record = CommentRecords.root(
            in: store.location, target: anchor.target, text: text, reaction: nil, via: via)
        try await store.append(record)
    }

    // MARK: - Live text

    private func startLive() {
        let live = liveFactory()
        self.live = live
        let store = self.store
        loop = Task { [weak self] in
            let requested = Date()
            do {
                try await live.prepare()
                let waited = Date().timeIntervalSince(requested)
                if waited >= 2 { log(String(format: "[Capture] Parakeet live transcriber ready after %.1fs", waited)) }
            } catch {
                let waited = Date().timeIntervalSince(requested)
                // The note was sent or stopped before the model was ready: not a Parakeet fault,
                // and no error for the user. The file run after the note still transcribes it.
                if error is CancellationError || Task.isCancelled {
                    log(String(format: "[Capture] note closed before the Parakeet live transcriber was ready (waited %.1fs); no live text for it", waited))
                    return
                }
                log(String(format: "[Capture] Parakeet live transcriber unavailable after %.1fs: %@", waited, error.localizedDescription))
                await MainActor.run {
                    guard let self, self.live === live else { return }
                    self.errorMessage = "Parakeet: \(error.localizedDescription)"
                }
                return
            }
            while !Task.isCancelled {
                await live.append(store.takeForLive())
                let text = try? await live.refresh()
                await MainActor.run {
                    // After a Send the old transcriber may still finish a refresh.
                    guard let self, self.live === live else { return }
                    if let text { self.liveText = text }
                    if self.listeningAnchor == nil { store.release(before: store.total) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Exact digital zero this long means the input stopped delivering sound
    /// (a Bluetooth headset switching profile or device), not a quiet room:
    /// a real microphone always has a noise floor.
    static let digitalSilenceLimit: Double = 2
    /// After this many restarts that brought no sound back, say so and retry less often.
    static let silentRestartsBeforeWarning = 3
    static let digitalSilenceRetryLimit: Double = 10

    static func silenceLimit(afterSilentRestarts restarts: Int) -> Double {
        restarts < silentRestartsBeforeWarning ? digitalSilenceLimit : digitalSilenceRetryLimit
    }

    private func startLevel() {
        // The meter needs more than the 1 s text refresh to look alive.
        levelLoop = Task { [weak self] in
            var failingSince: ContinuousClock.Instant?
            var silentRestarts = 0
            var silenceWarning: String?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                let stopped = (self.source as? MicrophoneAudioSource).map { !$0.isRunning } ?? false
                let silence = self.levelMeter.digitalSilenceSeconds
                let silent = !stopped && silence >= Self.silenceLimit(afterSilentRestarts: silentRestarts)
                if stopped || silent {
                    self.level = 0
                    if !self.inputTrouble { self.inputTrouble = true }
                    if self.isSpeech { self.isSpeech = false }
                    if self.pendingSend != nil { self.pendingSend = nil }
                    let device = self.inputDeviceName ?? "unknown input"
                    if silent {
                        log(String(format: "[Capture] %@ gave %.1f s of digital silence, restarting microphone (attempt %d)",
                                   device, silence, silentRestarts + 1))
                    }
                    self.source?.stop()
                    self.levelMeter.resetSilence()
                    let replacement = self.sourceFactory()
                    do {
                        _ = try self.startAudio(replacement)
                        self.source = replacement
                        self.stampInputDevice()
                        if failingSince != nil {
                            log("[Capture] \(self.inputDeviceName ?? device) restarted after a failed restart")
                            failingSince = nil
                        }
                        if silent {
                            silentRestarts += 1
                            if silentRestarts == Self.silentRestartsBeforeWarning {
                                let warning = "Микрофон «\(self.inputDeviceName ?? device)» передаёт тишину. Проверьте устройство ввода."
                                silenceWarning = warning
                                self.errorMessage = warning
                            }
                        }
                    } catch {
                        replacement.stop()
                        let now = ContinuousClock.now
                        if failingSince == nil {
                            failingSince = now
                            log("[Capture] \(device) failed to restart: \(Self.describe(error))")
                        }
                        if let since = failingSince, now - since >= self.microphoneRetryWindow {
                            log("[Capture] \(device) still failing after \(self.microphoneRetryWindow), stopping: \(Self.describe(error))")
                            self.errorMessage = Self.microphoneMessage(for: error, device: self.inputDeviceName ?? device)
                            await self.stop()
                            return
                        }
                    }
                    continue
                }
                if silence == 0, silentRestarts > 0 {
                    log("[Capture] \(self.inputDeviceName ?? "input") delivers sound again after \(silentRestarts) restart(s)")
                    silentRestarts = 0
                    if let warning = silenceWarning, self.errorMessage == warning { self.errorMessage = nil }
                    silenceWarning = nil
                }
                self.level = self.levelMeter.value
                self.refreshSignals()
            }
        }
    }

    private var inputDeviceName: String? {
        (source as? MicrophoneAudioSource)?.inputDevice?.name
    }

    /// Studio notes record which microphone they came from, as Wimm's recorder does.
    private func stampInputDevice() {
        guard let url = recordingURL, let device = (source as? MicrophoneAudioSource)?.inputDevice else { return }
        device.stamp(url)
    }

    private static func storeLiveText(_ text: String, for url: URL) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        FileStore.mutateTranscription(for: url) { transcription in
            guard !trimmed.isEmpty else { return false }
            transcription["transcript"] = trimmed
            transcription["localTranscript"] = trimmed
            transcription["speechStatus"] = TranscriptionSpeechStatus.speech.rawValue
            return true
        }
    }
}

private enum CaptureSessionError: LocalizedError {
    case missingGate
    case liveUnavailable
    case superseded
    var errorDescription: String? {
        switch self {
        case .missingGate: return "Recording gate was not ready."
        case .superseded: return "Another capture command came in."
        case .liveUnavailable: return "Live transcription is unavailable."
        }
    }
}

/// ADTS frames carry their own headers and remain readable after a crash.
public final class AudioFileSink: @unchecked Sendable {
    public static let fileExtension = "aac"

    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    public init(url: URL, format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 96_000,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    public func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, buffer.frameLength > 0 else { return }
        let target = file.processingFormat
        if buffer.format == target {
            converter = nil
            try? file.write(from: buffer)
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let capacity = ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(capacity)) else { return }
        // The route can change while the file is open. Keep a single AAC format
        // and feed each input buffer once into the streaming converter.
        let supplied = OSAllocatedUnfairLock(initialState: false)
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            let alreadySupplied = supplied.withLock { supplied in
                defer { supplied = true }
                return supplied
            }
            inputStatus.pointee = alreadySupplied ? .noDataNow : .haveData
            return alreadySupplied ? nil : buffer
        }
        if status != .error, output.frameLength > 0 {
            try? file.write(from: output)
        }
    }

    public func finish() {
        lock.lock(); defer { lock.unlock() }
        file = nil // Release the writer so it flushes the encoder.
    }
}

/// Perceptually scaled RMS of the loudest input channel, 0…1.
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Float = 0
    private var zeroSeconds: Double = 0
    private var signal = false
    public init() {}

    public var value: Float { lock.lock(); defer { lock.unlock() }; return current }
    /// How long the input has delivered nothing but exact zeros, in seconds.
    public var digitalSilenceSeconds: Double { lock.lock(); defer { lock.unlock() }; return zeroSeconds }

    /// A non-zero buffer has arrived since the last `resetSilence()`.
    public var hasSignal: Bool { lock.lock(); defer { lock.unlock() }; return signal }

    public func resetSilence() { lock.lock(); zeroSeconds = 0; signal = false; lock.unlock() }

    public func update(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let stride = buffer.format.isInterleaved ? channelCount : 1
        var loudest: Float = 0
        var allZero = true
        for channel in 0..<channelCount {
            let data = buffer.format.isInterleaved ? channels[0] + channel : channels[channel]
            var sum: Float = 0
            for i in 0..<count {
                let sample = data[i * stride]
                if sample != 0 { allZero = false }
                sum += sample * sample
            }
            loudest = max(loudest, (sum / Float(count)).squareRoot())
        }
        let seconds = Double(count) / max(buffer.format.sampleRate, 1)
        lock.lock()
        current = min(1, (loudest * 4).squareRoot())
        zeroSeconds = allZero ? zeroSeconds + seconds : 0
        if !allZero { signal = true }
        lock.unlock()
    }
}
