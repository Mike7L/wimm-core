import ArgumentParser
import Foundation
import WimmDomain
import WimmInfrastructure

/// Read-only report of stored cloud transcripts that are broken in one of the
/// three ways the 2026-10-24 local-ASR bake-off found: LOOP (the model repeats
/// one phrase), SILENCE (text over near-silent audio), SHORT (far fewer words
/// than the recording's detected speech holds — dropped stretches).
///
/// Never writes a sidecar. There is deliberately no `--apply`: what to do with
/// a broken transcript is a separate decision (docs/Transcript_Health_Audit.md).
struct AuditTranscripts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit-transcripts",
        abstract: "Report looped, silence-hallucinated and truncated transcripts (read-only)"
    )

    @Option(name: .long, help: "Only transcripts whose model or provider contains this (e.g. gemini, flash-lite)")
    var model: String?

    @Option(name: .long, help: "Loop threshold: share of repeated 6-grams")
    var loopShare: Double = 0.15

    @Option(name: .long, help: "SHORT threshold: fraction of the baseline words per speech-minute")
    var shortRatio: Double = 0.45

    @Option(name: .long, help: "SHORT only for recordings with at least this many speech minutes")
    var minSpeechMinutes: Double = 5

    @Option(name: .long, help: "Baseline words per speech-minute (default: library median)")
    var baseline: Double?

    @Flag(name: .long, help: "Skip audio decoding (LOOP only — fast)")
    var noAudio: Bool = false

    @Option(name: .long, help: "Limit number of notes scanned")
    var limit: Int?

    @Option(name: .long, help: "Write a per-note CSV report to this path")
    var csv: String?

    struct Row: Sendable {
        var name: String
        var model: String
        var audioSource = "original"
        var words = 0
        var loop: TranscriptHealth.LoopScore?
        var profile: TranscriptHealth.AudioProfile?
        var silence: TranscriptHealth.SilenceVerdict?
        var density: TranscriptHealth.DensityVerdict?
        var confidence: TranscriptHealth.ConfidenceVerdict?
        var flaggedNoSpeech = false
        var sentAudioSeconds: Double?
        var localWords: Int?
        var storedConfidence: Float?
        var storedP10Confidence: Double?
        var storedLowWordShare: Double?

        var isLoop: Bool = false
        var kinds: [String] {
            var out: [String] = []
            if isLoop { out.append("LOOP") }
            if silence?.isSuspect == true { out.append("SILENCE") }
            if density?.isSuspect == true { out.append("SHORT") }
            if confidence?.isSuspect == true { out.append("CONFIDENCE") }
            return out
        }
    }

    func run() async throws {
        let recDir = FileStore.recordingsDirectory()
        print("🔎 audit-transcripts — READ-ONLY — dir \(recDir.path)")
        let fm = FileManager.default
        let audioExts = DefaultFileStore.shared.supportedAudioExtensions
        // One audio file per note: the original when it exists, else the
        // derived copy `clean originals` left as the only audio (micro, then mini).
        var byBase: [String: URL] = [:]
        func rank(_ url: URL) -> Int {
            let base = url.deletingPathExtension().lastPathComponent
            return base.hasSuffix("_micro") ? 1 : base.hasSuffix("_mini") ? 2 : 0
        }
        for url in (try? fm.contentsOfDirectory(at: recDir, includingPropertiesForKeys: nil)) ?? []
        where audioExts.contains(url.pathExtension.lowercased()) {
            let base = FileStore.strippingDerivedAudioSuffix(url.deletingPathExtension().lastPathComponent)
            if let current = byBase[base], rank(current) <= rank(url) { continue }
            byBase[base] = url
        }

        var jobs: [(URL, Row, String)] = []
        for (base, audioURL) in byBase.sorted(by: { $0.key < $1.key }) {
            let anchor = recDir.appendingPathComponent(base).appendingPathExtension(audioURL.pathExtension)
            guard let stored = Self.storedCloudTranscript(for: anchor) else { continue }
            let (text, model) = (stored.text, stored.model)
            if let filter = self.model, !model.lowercased().contains(filter.lowercased()) { continue }
            var row = Row(name: anchor.lastPathComponent, model: model.isEmpty ? "?" : model)
            row.flaggedNoSpeech = stored.flaggedNoSpeech
            row.sentAudioSeconds = stored.sentAudioSeconds
            row.localWords = stored.localTranscript.map { TranscriptHealth.words($0).count }
            row.storedConfidence = stored.confidence
            row.storedP10Confidence = stored.p10Confidence
            row.storedLowWordShare = stored.lowConfidenceWordShare
            if rank(audioURL) > 0 { row.audioSource = rank(audioURL) == 1 ? "micro" : "mini" }
            jobs.append((audioURL, row, text))
        }
        if let limit { jobs = Array(jobs.prefix(limit)) }
        print("   transcripts: \(jobs.count)\(model.map { " (model ~ \($0))" } ?? "")\(noAudio ? " — audio skipped" : "")")

        let t0 = Date()
        let loopShare = self.loopShare
        let noAudio = self.noAudio
        let results = UnsafeRows(count: jobs.count)
        let done = UnsafeCounter()
        let jobsCopy = jobs
        DispatchQueue.concurrentPerform(iterations: jobsCopy.count) { i in
            var (url, row, text) = jobsCopy[i]
            let loop = TranscriptHealth.loopScore(text)
            row.words = loop.wordCount
            row.loop = loop
            row.isLoop = loop.repeatedShare > loopShare
            if let conf = row.storedConfidence {
                var c = TranscriptHealth.confidenceVerdict(confidence: conf)
                if let p10 = row.storedP10Confidence, let lowShare = row.storedLowWordShare {
                    let thresholds = TranscriptHealth.ConfidenceThresholds()
                    let reason: String? = c.mean < thresholds.minMeanConfidence
                        ? "low_confidence"
                        : (row.words >= thresholds.minWordsForWordStats && p10 < thresholds.minP10Confidence && lowShare > thresholds.maxLowWordShare
                            ? "low_word_confidence"
                            : nil)
                    c = TranscriptHealth.ConfidenceVerdict(
                        isSuspect: reason != nil,
                        reason: reason,
                        mean: c.mean,
                        p10: p10,
                        lowWordShare: lowShare
                    )
                }
                row.confidence = c
            }
            if !noAudio {
                if let p = TranscriptHealth.profile(of: url) {
                    row.profile = p
                } else {
                    row.audioSource = "unreadable"
                }
                // A loop already explains an impossible word count; judge silence only without one.
                if let p = row.profile, !row.isLoop {
                    row.silence = TranscriptHealth.silenceVerdict(wordCount: row.words, profile: p)
                }
            }
            results.set(i, row)
            let n = done.increment()
            if n % 100 == 0 { FileHandle.standardError.write(Data("  …\(n)/\(jobsCopy.count)\n".utf8)) }
        }
        var rows = results.all

        // Baseline: the library's own words per speech-minute over recordings
        // 1–10 speech-minutes long that no other detector suspects.
        let rates = rows.compactMap { row -> Double? in
            guard let p = row.profile, !row.isLoop, row.silence?.isSuspect != true else { return nil }
            let minutes = p.speechSeconds / 60
            guard minutes >= 1, minutes <= 10 else { return nil }
            return Double(row.words) / minutes
        }
        let base = baseline ?? TranscriptHealth.baselineWordsPerSpeechMinute(rates)
        var thresholds = TranscriptHealth.DensityThresholds()
        thresholds.maxRatio = shortRatio
        thresholds.minSpeechMinutes = minSpeechMinutes
        for i in rows.indices {
            guard let p = rows[i].profile, !rows[i].isLoop, rows[i].silence?.isSuspect != true else { continue }
            rows[i].density = TranscriptHealth.densityVerdict(
                wordCount: rows[i].words, profile: p, baseline: base,
                sentAudioSeconds: rows[i].sentAudioSeconds, localWordCount: rows[i].localWords,
                thresholds: thresholds
            )
        }

        printFindings(rows)
        printSummary(rows, baseline: base, baselineSample: rates.count, elapsed: Date().timeIntervalSince(t0))
        if let csv { try writeCSV(rows, to: csv) }
    }

    // MARK: - Sidecar read (read-only)

    struct StoredTranscript {
        var text: String
        var model: String
        var flaggedNoSpeech: Bool
        var sentAudioSeconds: Double?
        var localTranscript: String?
        var confidence: Float?
        var p10Confidence: Double?
        var lowConfidenceWordShare: Double?
    }

    /// The stored transcript and what the sidecar says about it. `nil` for no
    /// transcript, `[[NO_SPEECH]]`, or a stored error marker. Unlike
    /// `AuditSilence.storedTranscript`, never falls back to `refined_text` —
    /// that is a model rewrite, not the transcript.
    static func storedCloudTranscript(for audio: URL) -> StoredTranscript? {
        let metaURL = FileStore.metadataURL(forRecordingURL: audio)
        guard let data = try? Data(contentsOf: metaURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = obj["transcription"] as? [String: Any],
              let raw = t["transcript"] as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("[[NO_SPEECH]]"), !AuditSilence.isErrorMarker(text) else { return nil }
        let model = (t["model"] as? String) ?? (t["provider"] as? String) ?? ""
        let quality = t["quality"] as? [String: Any]
        let conf = (t["confidence"] as? NSNumber)?.floatValue ?? (quality?["confidence"] as? NSNumber)?.floatValue
        return StoredTranscript(
            text: text,
            model: model,
            flaggedNoSpeech: obj["suspectedNoSpeech"] as? Bool == true,
            sentAudioSeconds: (t["audioDurationSec"] as? NSNumber)?.doubleValue,
            localTranscript: t["localTranscript"] as? String,
            confidence: conf,
            p10Confidence: (quality?["p10Confidence"] as? NSNumber)?.doubleValue,
            lowConfidenceWordShare: (quality?["lowConfidenceWordShare"] as? NSNumber)?.doubleValue
        )
    }

    // MARK: - Report

    private func describe(_ r: Row) -> String {
        var parts: [String] = []
        if let p = r.profile { parts.append(String(format: "dur=%.1fmin speech=%.1fmin", p.duration / 60, p.speechSeconds / 60)) }
        parts.append("words=\(r.words)")
        if r.isLoop, let l = r.loop {
            parts.append(String(format: "%@ repeated6=%.2f top=%d×\"%@\"", l.isPhraseLoop ? "phrase" : "passage", l.repeatedShare, l.topCount, l.topPhrase))
        }
        if let s = r.silence, s.isSuspect {
            parts.append(String(format: "%@ peak=%.0fdBFS median=%.0fdBFS audible=%ds", s.reason ?? "", s.peakDBFS, s.medianDBFS, s.audibleSeconds))
        }
        if let d = r.density, d.isSuspect {
            parts.append(String(format: "%@ wpm=%.0f ratio=%.2f laterHalfSpeech=%.0f%%", d.reason ?? "", d.wordsPerSpeechMinute, d.ratio, d.laterHalfSpeechShare * 100))
            if let sent = r.sentAudioSeconds { parts.append(String(format: "sentAudio=%.0fs", sent)) }
            if let local = r.localWords { parts.append("localWords=\(local)") }
        }
        if let c = r.confidence, c.isSuspect {
            parts.append(String(format: "%@ conf=%.2f p10=%.2f lowShare=%.2f", c.reason ?? "", c.mean, c.p10, c.lowWordShare))
        }
        if r.flaggedNoSpeech { parts.append("suspectedNoSpeech=true") }
        if r.audioSource != "original" { parts.append("audio=\(r.audioSource)") }
        return parts.joined(separator: "  ")
    }

    private func printFindings(_ rows: [Row]) {
        for kind in ["LOOP", "SILENCE", "SHORT", "CONFIDENCE"] {
            let hits = rows.filter { $0.kinds.contains(kind) }
            if kind == "CONFIDENCE" && hits.isEmpty { continue }
            print("\n── \(kind) (\(hits.count)) ──")
            for r in hits { print("  \(r.name)  [\(r.model)]  \(describe(r))") }
        }
    }

    private func printSummary(_ rows: [Row], baseline: Double, baselineSample: Int, elapsed: Double) {
        func n(_ k: String, _ rs: [Row]) -> Int { rs.filter { $0.kinds.contains(k) }.count }
        print("\n══════════ SUMMARY ══════════")
        print("scanned:   \(rows.count)  (\(String(format: "%.1f", elapsed))s)")
        print(String(format: "baseline:  %.0f words / speech-minute (median of %d)", baseline, baselineSample))
        print("unreadable audio: \(rows.filter { $0.audioSource == "unreadable" }.count)")
        print("LOOP \(n("LOOP", rows))  SILENCE \(n("SILENCE", rows))  SHORT \(n("SHORT", rows))  any \(rows.filter { !$0.kinds.isEmpty }.count)")
        print("\nby model                         total  LOOP SILENCE SHORT")
        let byModel = Dictionary(grouping: rows, by: \.model).sorted { $0.value.count > $1.value.count }
        for (model, rs) in byModel {
            let label = model.padding(toLength: 32, withPad: " ", startingAt: 0)
            print("\(label) \(String(format: "%5d %5d %7d %5d", rs.count, n("LOOP", rs), n("SILENCE", rs), n("SHORT", rs)))")
        }
        print("\nRead-only: no sidecar was changed.")
    }

    private func writeCSV(_ rows: [Row], to path: String) throws {
        var out = "name,model,audio,durationMin,speechMin,words,repeated6,topCount,peakDBFS,medianDBFS,audibleSec,silenceReason,wpm,ratio,laterHalfSpeech,shortReason,sentAudioSec,localWords,suspectedNoSpeech,kinds\n"
        for r in rows {
            let p = r.profile, s = r.silence, d = r.density
            func f(_ v: Double?, _ fmt: String = "%.2f") -> String { v.map { String(format: fmt, $0) } ?? "" }
            out += [
                r.name, r.model, r.audioSource,
                f(p.map { $0.duration / 60 }), f(p.map { $0.speechSeconds / 60 }), "\(r.words)",
                f(r.loop?.repeatedShare, "%.3f"), "\(r.loop?.topCount ?? 0)",
                f(s?.peakDBFS, "%.1f"), f(s?.medianDBFS, "%.1f"), s.map { "\($0.audibleSeconds)" } ?? "", s?.reason ?? "",
                f(d?.wordsPerSpeechMinute, "%.0f"), f(d?.ratio), f(d?.laterHalfSpeechShare), d?.reason ?? "",
                f(r.sentAudioSeconds, "%.1f"), r.localWords.map(String.init) ?? "",
                "\(r.flaggedNoSpeech)", r.kinds.joined(separator: "+"),
            ].joined(separator: ",") + "\n"
        }
        try out.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        print("CSV → \(path)")
    }
}

/// Fixed-size result slots filled from `concurrentPerform`; each index is
/// written by exactly one iteration.
private final class UnsafeRows: @unchecked Sendable {
    private var rows: [AuditTranscripts.Row?]
    private let lock = NSLock()
    init(count: Int) { rows = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ row: AuditTranscripts.Row) { lock.lock(); rows[i] = row; lock.unlock() }
    var all: [AuditTranscripts.Row] { lock.lock(); defer { lock.unlock() }; return rows.compactMap { $0 } }
}

private final class UnsafeCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
