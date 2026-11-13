@preconcurrency import AVFoundation
import Foundation
import Observation
import WimmDocumentUI
import WimmDomain
import WimmInfrastructure

/// Records one spoken answer into its own audio note, with live Parakeet
/// text. Unlike `CaptureSession` it has no silence split or document
/// anchors; the evening note links to the answer under its question.
@MainActor @Observable
final class EveningVoiceRecorder {
    enum Phase: Equatable { case idle, starting, recording, finishing }

    private(set) var phase: Phase = .idle
    private(set) var liveText = ""
    private(set) var level: Float = 0
    /// The question being answered, while recording.
    private(set) var prompt: String?
    var errorMessage: String?

    @ObservationIgnored private var source: MicrophoneAudioSource?
    @ObservationIgnored private var sink: AudioFileSink?
    @ObservationIgnored private var live: ParakeetLiveTranscriber?
    @ObservationIgnored private var store = SampleStore()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var levelLoop: Task<Void, Never>?
    @ObservationIgnored private let meter = LevelMeter()
    @ObservationIgnored private var audioURL: URL?

    var isRecording: Bool { phase == .recording }

    func start(prompt: String, audioURL: URL) async {
        guard phase == .idle else { return }
        phase = .starting
        errorMessage = nil
        liveText = ""
        store = SampleStore()
        let source = MicrophoneAudioSource()
        do {
            try await source.requestAccess()
            let store = self.store, meter = self.meter
            let box = SinkHolder()
            let format = try source.start(bufferHandler: { buffer in
                box.sink?.write(buffer)
                meter.update(buffer)
                store.append(ParakeetLiveTranscriber.samples16k(from: buffer))
            }, completionHandler: { _ in })
            let sink = try AudioFileSink(url: audioURL, format: format)
            box.sink = sink
            self.source = source
            self.sink = sink
            self.audioURL = audioURL
            self.prompt = prompt
            phase = .recording
            startLive()
            levelLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self else { return }
                    self.level = self.meter.value
                }
            }
        } catch {
            source.stop()
            phase = .idle
            errorMessage = error.localizedDescription
        }
    }

    /// Stops and returns the audio file and its final text (empty when nothing was heard).
    func stop() async -> (url: URL, text: String, prompt: String)? {
        guard phase == .recording, let url = audioURL, let prompt else { return nil }
        phase = .finishing
        closeAudio()
        let oldLoop = loop
        oldLoop?.cancel(); loop = nil
        await oldLoop?.value
        var text = liveText
        if let live {
            await live.append(store.takeForLive())
            text = (try? await live.finish()) ?? liveText
        }
        live = nil
        liveText = text
        level = 0
        audioURL = nil
        self.prompt = nil
        phase = .idle
        return (url, text.trimmingCharacters(in: .whitespacesAndNewlines), prompt)
    }

    func finishForTermination() -> (url: URL, text: String, prompt: String)? {
        guard let url = audioURL, let prompt else { return nil }
        phase = .finishing
        closeAudio()
        loop?.cancel()
        return (url, liveText.trimmingCharacters(in: .whitespacesAndNewlines), prompt)
    }

    private func closeAudio() {
        source?.stop(); source = nil
        sink?.finish(); sink = nil
        levelLoop?.cancel(); levelLoop = nil
    }

    private func startLive() {
        let live = ParakeetLiveTranscriber()
        self.live = live
        let store = self.store
        loop = Task { [weak self] in
            do { try await live.prepare() } catch {
                await MainActor.run { self?.errorMessage = "Parakeet: \(error.localizedDescription)" }
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await live.append(store.takeForLive())
                let text = try? await live.refresh()
                await MainActor.run {
                    guard let self, self.live === live else { return }
                    if let text { self.liveText = text }
                    store.release(before: store.total)
                }
            }
        }
    }
}

/// Lets the audio-thread closure reach the file sink created after `start` returns the format.
private final class SinkHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sink: AudioFileSink?
    var sink: AudioFileSink? {
        get { lock.lock(); defer { lock.unlock() }; return _sink }
        set { lock.lock(); _sink = newValue; lock.unlock() }
    }
}
