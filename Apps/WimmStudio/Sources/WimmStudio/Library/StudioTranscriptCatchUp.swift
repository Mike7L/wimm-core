import Foundation
import WimmDomain
import WimmInfrastructure
import WimmTranscription

/// Studio's file run for recordings left without text: a capture whose live
/// Parakeet text never came (model still loading, failed, app quit), or a
/// recording synced in without a transcript. They go into the same
/// `RetranscriptionQueue` agents use and Studio drains it in its own process,
/// under the worker lock `wimm-cli transcript drain-queue` takes too — so a
/// note is never run twice, and a quit mid-run is picked up at next launch.
@MainActor
final class StudioTranscriptCatchUp {
    /// Called with each note the queue finished, so the library can refresh it.
    var onNoteTranscribed: (@MainActor @Sendable (URL) -> Void)?

    private let queue = RetranscriptionQueue()
    private var draining = false
    private var drainAgain = false

    /// Studio has no hear-model setting; Parakeet keeps the audio on the Mac.
    nonisolated static let model = ParakeetModel.ultra
    /// Recordings older than this are not swept in at launch.
    nonisolated static let sweepDays = 14
    /// A recording this fresh may still be getting its live text.
    nonisolated static let minimumAge: TimeInterval = 3 * 60

    func transcriptMissing(_ file: URL) {
        enqueue([file], reason: "studio: local file run after recording")
    }

    /// Recent recordings without text that the queue has never seen.
    func sweep(excluding active: URL?) {
        let queue = self.queue
        Task.detached(priority: .utility) {
            let cutoff = Date().addingTimeInterval(-Double(Self.sweepDays) * 86_400)
            let now = Date()
            let listed = (try? FileManager.default.contentsOfDirectory(
                at: FileStore.recordingsDirectory(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            let files = listed.filter { file in
                guard file.standardizedFileURL != active?.standardizedFileURL,
                      let date = FileStore.recordingDateFromFileName(file),
                      date >= cutoff, now.timeIntervalSince(date) >= Self.minimumAge,
                      queue.latest(forFile: file.path) == nil else { return false }
                return Self.needsTranscript(file: file, meta: Self.sidecar(of: file))
            }
            await MainActor.run { [weak self] in
                self?.enqueue(files, reason: "studio: recording without a transcript at launch")
            }
        }
    }

    /// Audio with no text and no verdict yet. A no-speech result, a
    /// sub-second tap and any text (an iPhone's plain-string one included)
    /// count as done.
    nonisolated static func needsTranscript(file: URL, meta: [String: Any]) -> Bool {
        guard FileStore.isAudioFile(file), !FileStore.isDerivedAudioFile(file) else { return false }
        if let duration = meta["duration"] as? Double, duration < 1 { return false }
        switch meta[MetadataKey.transcription.rawValue] {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let run as [String: Any]:
            if run["speechStatus"] as? String == TranscriptionSpeechStatus.noSpeech.rawValue { return false }
            let transcript = (run["transcript"] as? String) ?? ""
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    private nonisolated static func sidecar(of file: URL) -> [String: Any] {
        (try? Data(contentsOf: FileStore.metadataURL(forRecordingURL: file)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func enqueue(_ files: [URL], reason: String) {
        guard !files.isEmpty else { return }
        let now = Date()
        let requests = files.map { file in
            RetranscriptionQueue.Entry(
                file: file.path,
                noteId: file.stableUUID.uuidString,
                model: Self.model, analyze: false, reason: reason, requestedAt: now)
        }
        do {
            let results = try queue.enqueue(requests)
            let queued = results.filter { $0 == .queued }.count
            log("[Transcribe] queued \(queued) of \(files.count) recording(s) without text (\(reason))")
        } catch {
            log("[Transcribe] could not queue \(files.count) recording(s): \(error.localizedDescription)")
        }
        drain()
    }

    /// Works the queue off in the background; a call while it runs makes it
    /// look once more when done.
    func drain() {
        guard !draining else { drainAgain = true; return }
        guard queue.hasQueued else { return }
        draining = true
        let queue = self.queue, notify = onNoteTranscribed
        Task.detached(priority: .utility) { [weak self] in
            do {
                let done = try await RetranscriptionWorker.drain(
                    queue: queue, origin: "WimmStudio.TranscriptCatchUp",
                    defaultReason: "Studio local file run", allowsAnalysis: false
                ) { entry, outcome in
                    let name = URL(fileURLWithPath: entry.file).lastPathComponent
                    guard let outcome else { return log("[Transcribe] \(name) via \(entry.model)…") }
                    log("[Transcribe] \(name): \(outcome.failed ? "FAILED " : "")\(outcome.summary)")
                    let file = URL(fileURLWithPath: entry.parentFile ?? entry.file)
                    if let notify { Task { @MainActor in notify(file) } }
                }
                if done == nil { log("[Transcribe] another worker holds the queue; it will run the requests") }
            } catch {
                log("[Transcribe] queue failed: \(error.localizedDescription)")
            }
            await self?.drainFinished()
        }
    }

    private func drainFinished() {
        draining = false
        if drainAgain { drainAgain = false; drain() }
    }
}
