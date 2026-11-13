import ArgumentParser
import AVFoundation
import Foundation
import WimmDomain
import Speech
import WimmInfrastructure

/// Non-destructive backfill: finds existing notes whose stored transcript was
/// almost certainly fabricated by a cloud transcriber on silence/noise, and
/// FLAGS them for review. Never deletes audio or clears transcripts.
///
/// Classification of a note that carries a non-empty stored transcript:
///   - rms < floor                 → SILENT      (no acoustic signal at all)
///   - floor ≤ rms < speechRMS      → run on-device SF (ru+en):
///        SF empty                  → ASR_EMPTY  (signal present, no speech found)
///        SF found speech           → OK
///   - rms ≥ speechRMS              → OK          (loud enough; assume speech)
///
/// SILENT and ASR_EMPTY notes are flagged. SF false-negatives on quiet/accented
/// speech is why this only *flags* (reversible) rather than deletes.
struct AuditSilence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit-silence",
        abstract: "Flag notes whose transcript was hallucinated on silent/noisy audio"
    )

    @Flag(name: .long, help: "Write review flags to metadata (default: dry-run report only)")
    var apply: Bool = false

    @Option(name: .long, help: "Only consider notes whose stored transcript is at least N chars")
    var minMetaLen: Int = 40

    @Option(name: .long, help: "RMS silence floor (below = SILENT)")
    var floor: Double = 0.0035

    @Option(name: .long, help: "RMS above which we assume speech without running ASR")
    var speechRMS: Double = 0.02

    @Flag(name: .long, help: "Also probe the ambiguous RMS band with on-device ASR (low precision — see notes)")
    var asrBand: Bool = false

    @Option(name: .long, help: "Comma-separated on-device ASR locales for the ambiguous band")
    var locales: String = "ru-RU,en-US"

    @Option(name: .long, help: "Probe only the first N seconds for RMS (0 = whole file)")
    var probeSeconds: Double = 0

    @Option(name: .long, help: "Limit number of notes scanned")
    var limit: Int?

    @Flag(name: .long, help: "Shuffle before applying --limit (random sample)")
    var shuffle: Bool = false

    @Option(name: .long, help: "Write a per-note CSV report to this path")
    var csv: String?

    @Flag(name: .long, help: "Re-check previously flagged notes and clear flags whose audio has an audible window (peak RMS ≥ floor)")
    var clearStale: Bool = false

    enum Klass: String {
        case silent = "SILENT"          // rms below floor — fabricated transcript, flagged
        case asrEmpty = "ASR_EMPTY"     // ambiguous band, on-device ASR found nothing (low precision)
        case errorMarker = "ERROR_MARKER" // stored "Transcription failed (…)" — a known error, not a hallucination
        case ok = "OK"
        case error = "ERROR"            // file unreadable
    }

    struct Row {
        var name: String
        var rms: Float
        var metaLen: Int
        var klass: Klass
        var flagged: Bool
    }

    func run() async throws {
        let localeIDs = locales.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let recDir = FileStore.recordingsDirectory()
        print("🔎 audit-silence — \(apply ? "APPLY (writing flags)" : "DRY-RUN") — dir \(recDir.path)")
        print("   floor=\(floor) speechRMS=\(speechRMS) locales=\(localeIDs.joined(separator: "+"))")

        let fm = FileManager.default
        var audio = (try? fm.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)) ?? []
        audio = audio.filter { $0.pathExtension == "m4a" && !FileStore.isDerivedAudioFile($0) }

        // Keep only notes whose stored transcript is substantive.
        var candidates: [(URL, String)] = []
        for url in audio {
            let text = Self.storedTranscript(for: url)
            if text.count >= minMetaLen { candidates.append((url, text)) }
        }
        if shuffle { candidates.shuffle() }
        if let limit { candidates = Array(candidates.prefix(limit)) }

        print("   candidates with transcript ≥\(minMetaLen) chars: \(candidates.count)")
        if asrBand { print("   --asr-band ON: probing ambiguous band with on-device ASR (LOW precision — quiet/Russian speech reads as empty)") }
        print("")

        var rows: [Row] = []
        let t0 = Date()
        for (i, (url, text)) in candidates.enumerated() {
            var row = Row(name: url.lastPathComponent, rms: 0, metaLen: text.count, klass: .error, flagged: false)

            if Self.isErrorMarker(text) {
                row.klass = .errorMarker
            // Peak windowed RMS, not a span mean: pauses and a quiet lead-in drag
            // a mean below the floor even when the note holds a real conversation
            // (the 2026-07 false "Maybe silent" class). Matches the live gate.
            } else if let rms = AudioEnergyProbe.peakWindowRMS(of: url, maxSeconds: probeSeconds) {
                row.rms = rms
                if Double(rms) < floor {
                    row.klass = .silent
                } else if Double(rms) >= speechRMS || !asrBand {
                    // Loud enough, or ASR band not requested → trust it (don't flag).
                    row.klass = .ok
                } else {
                    let hasSpeech = await Self.onDeviceHasSpeech(url: url, locales: localeIDs)
                    row.klass = hasSpeech ? .ok : .asrEmpty
                }
            }

            // Default policy: only the high-precision SILENT class is flagged.
            // ASR_EMPTY is opt-in and written with a distinct, softer reason.
            let reason: String?
            switch row.klass {
            case .silent: reason = "silent"
            case .asrEmpty: reason = "asr_unverified"
            default: reason = nil
            }
            if let reason {
                row.flagged = true
                if apply {
                    FileStore.upsertMetadata(for: url, updates: [
                        "suspectedNoSpeech": true,
                        "suspectedNoSpeechReason": reason,
                        "acousticRMS": Double(row.rms),
                        "silenceAuditedAt": ISO8601.now,
                    ])
                }
            }
            rows.append(row)
            if (i + 1) % 25 == 0 || i + 1 == candidates.count {
                FileHandle.standardError.write(Data("  …\(i + 1)/\(candidates.count)\n".utf8))
            }
        }

        printSummary(rows: rows, elapsed: Date().timeIntervalSince(t0))
        if let csvPath = csv { try writeCSV(rows: rows, to: csvPath) }
        if !apply, rows.contains(where: { $0.flagged }) {
            print("\nRe-run with --apply to write review flags (non-destructive).")
        }
        if clearStale { clearStaleFlags(audio: audio) }
    }

    /// Reasons derived purely from the audio signal — safe to re-derive and
    /// clear when the audio turns out to contain an audible window. Flags from
    /// other sources are left alone.
    private static let acousticReasons: Set<String> = [
        "silent", "asr_unverified", "rms_below_floor_live_speech",
    ]

    /// Clears `suspectedNoSpeech` on notes flagged by an earlier acoustic pass
    /// whose audio has at least one window at/above the floor. Earlier passes
    /// compared the floor against a span *mean*, which pauses and a quiet
    /// lead-in drag below the floor on real conversations.
    private func clearStaleFlags(audio: [URL]) {
        print("\n🔎 clear-stale — re-checking flagged notes with peak-window RMS (floor=\(floor))")
        var checked = 0, cleared = 0, kept = 0, unreadable = 0
        for url in audio {
            let metaURL = FileStore.metadataURL(forRecordingURL: url)
            guard let data = try? Data(contentsOf: metaURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["suspectedNoSpeech"] as? Bool == true,
                  Self.acousticReasons.contains(obj["suspectedNoSpeechReason"] as? String ?? "")
            else { continue }
            checked += 1
            guard let peak = AudioEnergyProbe.peakWindowRMS(of: url, maxSeconds: probeSeconds) else {
                unreadable += 1
                continue
            }
            if Double(peak) >= floor {
                cleared += 1
                let was = obj["suspectedNoSpeechReason"] as? String ?? "?"
                print(String(format: "  clear %@ peak=%.4f was=%@", url.lastPathComponent, peak, was))
                if apply {
                    FileStore.upsertMetadata(for: url, updates: [
                        "suspectedNoSpeech": false,
                        "suspectedNoSpeechReason": "cleared_audible_peak",
                        "acousticRMS": Double(peak),
                        "silenceAuditedAt": ISO8601.now,
                    ])
                }
            } else {
                kept += 1
            }
        }
        print("clear-stale: checked=\(checked) cleared=\(cleared)\(apply ? "" : " (dry-run)") kept=\(kept) unreadable=\(unreadable)")
    }

    private func printSummary(rows: [Row], elapsed: Double) {
        func count(_ k: Klass) -> Int { rows.filter { $0.klass == k }.count }
        let flagged = rows.filter { $0.flagged }.count
        print("\n══════════ SUMMARY ══════════")
        print("scanned:      \(rows.count)  (\(String(format: "%.1f", elapsed))s)")
        print("OK:           \(count(.ok))")
        print("SILENT:       \(count(.silent))   (flagged — reason=silent)")
        print("ASR_EMPTY:    \(count(.asrEmpty))   (flagged — reason=asr_unverified, low precision)")
        print("ERROR_MARKER: \(count(.errorMarker))   (stored transcription error — not flagged)")
        print("ERROR:        \(count(.error))")
        print("flagged total: \(flagged)\(apply ? " — written" : " — dry-run")")
    }

    private func writeCSV(rows: [Row], to path: String) throws {
        var out = "name,rms,metaLen,class,flagged\n"
        for r in rows {
            out += "\(r.name),\(String(format: "%.4f", r.rms)),\(r.metaLen),\(r.klass.rawValue),\(r.flagged)\n"
        }
        try out.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        print("CSV → \(path)")
    }

    // TODO(audit coverage): a small set of real audio notes carry a
    // `noteCard.summary` but no `transcription.transcript` / `refined_text` /
    // legacy `text` — so `storedTranscript` returns "" and they drop out of the
    // candidate set. Measured 2026-07-07: of 1328 non-derived .m4a files only 11
    // are summary-only (the rest of the library's ~2886 summary-only .meta.json
    // are Evernote .txt imports with no audio at all — correctly out of scope,
    // the caller already filters to .m4a). The 11 look like the HUD-recording
    // path, which writes the note card but not the raw transcript into meta (cf.
    // wimm-journal-refresh memory). Fix by teaching that path to persist the
    // transcript. Note: `summary` is NOT a safe fallback — it's LLM-generated and
    // can restate a hallucinated silence transcript instead of exposing it.
    static func storedTranscript(for audio: URL) -> String {
        let metaURL = FileStore.metadataURL(forRecordingURL: audio)
        guard let data = try? Data(contentsOf: metaURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        func trimmed(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        // Current schema nests the cloud transcript; fall back to the legacy flat fields.
        let transcript = trimmed((obj["transcription"] as? [String: Any])?["transcript"] as? String)
        if !transcript.isEmpty { return transcript }
        let refined = trimmed((obj["noteCard"] as? [String: Any])?["refined_text"] as? String)
        if !refined.isEmpty { return refined }
        return trimmed((obj["text"] as? String) ?? (obj["refinedText"] as? String))
    }

    /// Stored "Transcription failed (err: …)" markers are a known error state, not a
    /// hallucination — classified separately so they don't inflate the flag count.
    static func isErrorMarker(_ text: String) -> Bool {
        let low = text.lowercased()
        return low.hasPrefix("transcription failed") || low.contains("api error") || low.contains("err:")
    }

    /// On-device speech check across locales; true as soon as any locale finds words.
    static func onDeviceHasSpeech(url: URL, locales: [String]) async -> Bool {
        for id in locales {
            if await transcribe(url: url, locale: id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return true
            }
        }
        return false
    }

    static func transcribe(url: URL, locale: String) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
                  recognizer.isAvailable else { cont.resume(returning: ""); return }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result, result.isFinal {
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    cont.resume(returning: "")
                }
            }
        }
    }
}
