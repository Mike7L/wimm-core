import ArgumentParser
import AVFoundation
import Foundation
import WimmDomain
import WimmInfrastructure

/// Runs the on-device pipeline on one audio file without touching the library: Parakeet with
/// word timings, the offline diarizer, and the speaker split. `--live` also replays the file
/// through the HUD's live preview loop to measure its cost and how far its text drifts from the
/// file run. Read-only; for tuning against real recordings.
///
/// `--missing` instead catches up the library's Parakeet notes that should have a speaker split
/// but do not (the detached split was killed or failed): dry-run by default, `--apply` writes it
/// through `SpeakerTurnsBackfill`, only while the stored transcript is still the one it split.
struct Speakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers",
        abstract: "Split audio by speaker on-device (a file read-only, or --missing for the library)"
    )

    @Argument(help: "Path to the audio file (omit with --missing)")
    var path: String?

    @Flag(name: .long, help: "Split library notes with a Parakeet transcript but no speaker split")
    var missing: Bool = false

    @Flag(name: .long, help: "With --missing: write the splits (otherwise dry-run)")
    var apply: Bool = false

    @Option(name: .long, help: "With --missing: process at most this many notes")
    var limit: Int?

    @Option(name: .long, help: "Transcription language (Auto, ru, en, …)")
    var language: String = "ru"

    @Flag(name: .long, help: "Also replay the file through the live preview loop")
    var live: Bool = false

    @Option(name: .long, help: "Import a local owner voice profile JSON (dry-run without --apply)")
    var importOwnerProfile: String?

    @Flag(name: .long, help: "Classify speech/owner/count without retranscribing; --apply stores the label")
    var classify: Bool = false

    func run() async throws {
        if let importOwnerProfile {
            let file = URL(fileURLWithPath: (importOwnerProfile as NSString).expandingTildeInPath)
            let profile = try JSONDecoder().decode(OwnerVoiceProfile.self, from: Data(contentsOf: file))
            guard profile.isValid else { throw ValidationError("Invalid owner voice profile") }
            if apply { try OwnerVoiceProfile.install(from: file) }
            print("Owner voice profile \(profile.id.prefix(12)): \(apply ? "installed locally" : "valid; pass --apply to install")")
            return
        }
        if missing { return try await backfill() }
        guard let path else { throw ValidationError("Give an audio file, or --missing") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No such file: \(url.path)")
        }
        if classify {
            if apply {
                try await AudioSpeechClassification.detectIfNeeded(for: url)
                print("Speech classification checked; manual corrections are preserved.")
            } else {
                let spans = try await LocalSpeakerDiarizer.spans(for: url)
                if let detection = try await AudioSpeechClassification.classify(file: url, spans: spans) {
                    let data = try JSONEncoder().encode(detection)
                    print(String(decoding: data, as: UTF8.self))
                } else {
                    print("Unknown: no reliable speaker evidence.")
                }
            }
            return
        }

        let adapter = ParakeetTranscriptionAdapter(modelIdentifier: ParakeetModel.ultra, language: language)
        try await ParakeetTranscriptionAdapter.preload()
        var started = Date()
        let transcript = try await adapter.transcribe(at: url)
        let asrSeconds = Date().timeIntervalSince(started)

        started = Date()
        let record = try await LocalSpeakerDiarizer.record(for: url, words: transcript.timedWords)
        let diarSeconds = Date().timeIntervalSince(started)

        let audio = transcript.audioSeconds
        print(String(format: "audio %.1fs · ASR %.2fs (%.0f×) · diarization %.2fs (%.0f×) · %d words · speakers %d",
                     audio, asrSeconds, audio / max(asrSeconds, 0.001), diarSeconds, audio / max(diarSeconds, 0.001),
                     transcript.words, record.speakers))
        if record.isMultiSpeaker {
            for turn in record.turns {
                print(String(format: "[%@–%@] Голос %d: %@", clock(turn.start), clock(turn.end), turn.speaker, turn.text))
            }
        } else {
            print("one speaker — no split stored")
        }

        if live {
            try await replayLive(url: url, reference: transcript.text)
        }
    }

    private func backfill() async throws {
        var pending = SpeakerTurnsBackfill.candidates()
        if let limit { pending = Array(pending.prefix(limit)) }
        print("speakers --missing — \(apply ? "APPLY" : "dry-run") — \(pending.count) note(s) without a speaker split")
        guard !pending.isEmpty else { return }
        try await ParakeetTranscriptionAdapter.preload()
        var counts: [String: Int] = [:]
        for candidate in pending {
            let started = Date()
            let outcome = await SpeakerTurnsBackfill.run(
                candidate, languages: [language], apply: apply,
                transcribe: SpeakerTurnsBackfill.onDeviceTranscribe,
                diarize: SpeakerTurnsBackfill.onDeviceDiarize)
            let label: String
            switch outcome {
            case .stored(let n): label = "stored speakers=\(n)"
            case .wouldStore(let n): label = "would store speakers=\(n)"
            case .transcriptChanged: label = "skipped: transcript changed"
            case .textMismatch: label = "skipped: re-read differs from the stored transcript"
            case .tooShort: label = "skipped: too short"
            case .failed(let error): label = "failed: \(error)"
            }
            counts[String(label.prefix(while: { $0 != ":" && $0 != " " })), default: 0] += 1
            print(String(format: "%@  %@  (%.1fs)", candidate.audio.lastPathComponent, label, Date().timeIntervalSince(started)))
        }
        print(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        if !apply { print("Dry-run: no sidecar was changed. Pass --apply to write.") }
    }

    /// Feeds the file in 100 ms buffers and refreshes once per second of audio, as the HUD does.
    private func replayLive(url: URL, reference: String) async throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        let transcriber = ParakeetLiveTranscriber(modelIdentifier: ParakeetModel.ultra, language: language)
        try await transcriber.prepare()

        var refreshTimes: [Double] = []
        var firstTextAt: Double?
        var audioSeconds = 0.0
        var sinceRefresh = 0.0
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { break }
            await transcriber.append(ParakeetLiveTranscriber.samples16k(from: buffer))
            let seconds = Double(buffer.frameLength) / format.sampleRate
            audioSeconds += seconds
            sinceRefresh += seconds
            guard sinceRefresh >= 1 else { continue }
            sinceRefresh = 0
            let started = Date()
            let text = try await transcriber.refresh()
            refreshTimes.append(Date().timeIntervalSince(started))
            if firstTextAt == nil, let text, !text.isEmpty { firstTextAt = audioSeconds }
        }
        let started = Date()
        let final = try await transcriber.finish()
        let finishTime = Date().timeIntervalSince(started)

        let sorted = refreshTimes.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        print(String(format: "live: %d refreshes · median %.3fs · max %.3fs · finish %.2fs · first text at %.1fs of audio",
                     refreshTimes.count, median, sorted.last ?? 0, finishTime, firstTextAt ?? -1))
        print(String(format: "live vs file run: WER %.2f (%d vs %d words)",
                     Self.wordErrorRate(hypothesis: final, reference: reference),
                     Self.words(final).count, Self.words(reference).count))
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
    }

    static func wordErrorRate(hypothesis: String, reference: String) -> Double {
        let h = words(hypothesis), r = words(reference)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        var previous = Array(0...h.count)
        for i in 1...r.count {
            var current = [i] + Array(repeating: 0, count: h.count)
            for j in 1...max(h.count, 1) where j <= h.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (r[i - 1] == h[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[h.count]) / Double(r.count)
    }
}
