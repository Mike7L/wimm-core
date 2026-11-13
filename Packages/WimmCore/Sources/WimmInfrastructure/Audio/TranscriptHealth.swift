import Foundation

/// Read-only detectors for three ways a stored cloud transcript is broken,
/// found by the 2026-10-24 local-ASR bake-off: the model loops on one phrase,
/// it writes text over near-silent audio, or it drops whole stretches of a
/// long recording. Pure functions over text and per-window RMS, so they are
/// unit-testable without audio files; `profile(of:)` is the one decoding edge.
///
/// Nothing here writes. Detection only reports — any repair (re-transcribe,
/// fall back to a local transcript) is a separate decision.
public enum TranscriptHealth {

    // MARK: Tokens

    /// Lower-cased word tokens (letters/digits; `ё` folded to `е`).
    public static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .split { !($0.isLetter || $0.isNumber) }
            .map(String.init)
    }

    // MARK: 1. Loops

    public struct LoopScore: Equatable, Sendable {
        public let wordCount: Int
        /// Share of n-gram occurrences that repeat an earlier identical n-gram
        /// (`1 - distinct / total`). 0 for text shorter than `minWords`.
        public let repeatedShare: Double
        /// The most frequent n-gram and how often it occurs.
        public let topPhrase: String
        public let topCount: Int

        /// One short phrase repeated over and over ("я не помню" ×534), as
        /// opposed to a whole passage written twice (a duplicated chunk), where
        /// many distinct n-grams each occur only a few times.
        public var isPhraseLoop: Bool { topCount >= 10 }
    }

    public static func loopScore(_ text: String, n: Int = 6, minWords: Int = 40) -> LoopScore {
        let tokens = words(text)
        guard n > 0, tokens.count >= max(minWords, n) else {
            return LoopScore(wordCount: tokens.count, repeatedShare: 0, topPhrase: "", topCount: 0)
        }
        var counts: [ArraySlice<String>: Int] = [:]
        let total = tokens.count - n + 1
        for start in 0..<total {
            counts[tokens[start..<start + n], default: 0] += 1
        }
        let top = counts.max { a, b in a.value < b.value || (a.value == b.value && a.key.joined() > b.key.joined()) }
        return LoopScore(
            wordCount: tokens.count,
            repeatedShare: 1 - Double(counts.count) / Double(total),
            topPhrase: top?.key.joined(separator: " ") ?? "",
            topCount: top?.value ?? 0
        )
    }

    // MARK: Audio profile

    /// What the detectors need from the audio: per-second RMS (the speech
    /// gate's resolution) and the silence map's speech time.
    public struct AudioProfile: Equatable, Sendable {
        public let duration: Double
        public let secondRMS: [Float]
        /// Speech intervals from `AudioSilenceMap` (duration minus its gaps).
        public let speechIntervals: [AudioSilenceMap.Interval]

        public init(duration: Double, secondRMS: [Float], speechIntervals: [AudioSilenceMap.Interval]) {
            self.duration = duration
            self.secondRMS = secondRMS
            self.speechIntervals = speechIntervals
        }

        public var speechSeconds: Double { speechIntervals.reduce(0) { $0 + $1.length } }

        /// Speech seconds falling inside `[start, end)`.
        public func speechSeconds(from start: Double, to end: Double) -> Double {
            speechIntervals.reduce(0) { sum, interval in
                sum + max(0, min(end, interval.end) - max(start, interval.start))
            }
        }

        public var peakRMS: Float { secondRMS.max() ?? 0 }
        public var medianRMS: Float {
            guard !secondRMS.isEmpty else { return 0 }
            return secondRMS.sorted()[secondRMS.count / 2]
        }
        /// Seconds at or above `floor` — the live speech gate's "audible" test.
        public func audibleSeconds(floor: Float) -> Int { secondRMS.filter { $0 >= floor }.count }
    }

    /// Builds a profile from the silence map's fine windows (pure).
    public static func profile(
        windowRMS: [Float],
        windowSeconds: Double,
        configuration: AudioSilenceMap.Configuration = .init()
    ) -> AudioProfile {
        let map = AudioSilenceMap.build(windowRMS: windowRMS, windowSeconds: windowSeconds, configuration: configuration)
        let perSecond = max(1, Int((1.0 / windowSeconds).rounded()))
        var seconds: [Float] = []
        seconds.reserveCapacity(windowRMS.count / perSecond + 1)
        var index = 0
        while index < windowRMS.count {
            let chunk = windowRMS[index..<min(windowRMS.count, index + perSecond)]
            let meanSquare = chunk.reduce(Float(0)) { $0 + $1 * $1 } / Float(chunk.count)
            seconds.append(meanSquare.squareRoot())
            index += perSecond
        }
        var speech: [AudioSilenceMap.Interval] = []
        var cursor = 0.0
        for gap in map.silences {
            if gap.start > cursor { speech.append(.init(start: cursor, end: gap.start)) }
            cursor = max(cursor, gap.end)
        }
        if map.duration > cursor { speech.append(.init(start: cursor, end: map.duration)) }
        return AudioProfile(duration: map.duration, secondRMS: seconds, speechIntervals: speech)
    }

    /// Decodes the file once. Fail-open: `nil` when it cannot be decoded.
    public static func profile(
        of url: URL,
        configuration: AudioSilenceMap.Configuration = .init()
    ) -> AudioProfile? {
        guard let rms = AudioSilenceMap.windowRMS(of: url, windowSeconds: configuration.windowSeconds) else {
            return nil
        }
        return profile(windowRMS: rms, windowSeconds: configuration.windowSeconds, configuration: configuration)
    }

    public static func dBFS(_ rms: Float) -> Double {
        rms > 0 ? 20 * log10(Double(rms)) : -160
    }

    // MARK: 2. Text on silence

    public struct SilenceVerdict: Equatable, Sendable {
        public let isSuspect: Bool
        /// `silent` (peak under −55 dBFS), `near_silent`
        /// (quiet peak over a near-digital-silence median), or
        /// `more_words_than_speech` (more words than the detected speech could
        /// hold — seen as text over a click, an ad over 2 s of audio, or a
        /// summary written instead of a transcript).
        public let reason: String?
        public let peakDBFS: Double
        public let medianDBFS: Double
        public let audibleSeconds: Int
    }

    public struct SilenceThresholds: Equatable, Sendable {
        /// Live speech-gate floor: peak 1 s-window RMS (≈ −49 dBFS). Only used
        /// to report audible seconds — on the 2026-10-24 library pass, coherent
        /// quiet night dictation peaked at −50…−53 dBFS (median ≈ −62), so a
        /// peak under the gate alone is not evidence of a hallucination.
        public var gateFloor: Float = 0.0035
        /// Below this peak nothing was said (−55 dBFS).
        public var silentPeak: Float = 0.0018
        /// A peak this quiet only counts as silence together with `nearSilentMedian`.
        public var quietPeak: Float = 0.01        // −40 dBFS
        public var nearSilentMedian: Float = 0.0003 // ≈ −70 dBFS
        /// Nobody speaks more than this many words per second of detected speech.
        public var maxWordsPerSpeechSecond: Double = 5
        /// Transcripts shorter than this are not worth reporting.
        public var minWords: Int = 3
        public init() {}
    }

    public static func silenceVerdict(
        wordCount: Int,
        profile: AudioProfile,
        thresholds: SilenceThresholds = .init()
    ) -> SilenceVerdict {
        let peak = profile.peakRMS
        let median = profile.medianRMS
        let audible = profile.audibleSeconds(floor: thresholds.gateFloor)
        var reason: String?
        if wordCount >= thresholds.minWords, !profile.secondRMS.isEmpty {
            if peak < thresholds.silentPeak {
                reason = "silent"
            } else if peak < thresholds.quietPeak, median < thresholds.nearSilentMedian {
                reason = "near_silent"
            } else if Double(wordCount) > thresholds.maxWordsPerSpeechSecond * profile.speechSeconds + 10 {
                reason = "more_words_than_speech"
            }
        }
        return SilenceVerdict(
            isSuspect: reason != nil,
            reason: reason,
            peakDBFS: dBFS(peak),
            medianDBFS: dBFS(median),
            audibleSeconds: audible
        )
    }

    // MARK: 3. Truncation / omission

    public struct DensityVerdict: Equatable, Sendable {
        public let isSuspect: Bool
        /// `sent_audio_shorter` (the transcriber recorded a much shorter audio
        /// duration than the file's speech), `fewer_than_local` (far fewer words
        /// than the stored local streaming transcript), or `sparse` (far below
        /// the library's words per speech-minute).
        public let reason: String?
        /// Words per minute of detected speech.
        public let wordsPerSpeechMinute: Double
        /// `wordsPerSpeechMinute / baseline`.
        public let ratio: Double
        /// Share of the recording's speech that sits in its second half —
        /// a transcript missing its tail can't be told apart from one missing
        /// its middle without timestamps, but this shows how much speech the
        /// later part holds.
        public let laterHalfSpeechShare: Double
        public let speechMinutes: Double
    }

    public struct DensityThresholds: Equatable, Sendable {
        /// Only recordings with at least this much detected speech are judged —
        /// short notes are noisy and rarely truncated.
        public var minSpeechMinutes: Double = 5
        /// Flag below this fraction of the baseline words-per-speech-minute.
        public var maxRatio: Double = 0.45
        /// `sent_audio_shorter` below this fraction of the detected speech
        /// (the upload is silence-trimmed, so it may be shorter than the file,
        /// never much shorter than its speech).
        public var maxSentAudioShare: Double = 0.5
        /// …and only together with a density below this fraction of the baseline.
        public var maxRatioWithShortSentAudio: Double = 0.7
        /// `fewer_than_local` below this fraction of the local transcript's words.
        public var maxLocalWordShare: Double = 0.5
        /// …only when the local transcript has at least this many words.
        public var minLocalWords: Int = 50
        /// The direct signals need at least this much detected speech.
        public var minSpeechSecondsForDirectSignals: Double = 60
        public init() {}
    }

    /// `baseline` is the library's own typical words per speech-minute
    /// (median over healthy recordings — see `baselineWordsPerSpeechMinute`).
    /// `sentAudioSeconds` is the duration the transcriber recorded
    /// (`transcription.audioDurationSec`); `localWordCount` the word count of
    /// the stored local streaming transcript — both optional, both direct
    /// evidence where the baseline comparison is only statistical.
    public static func densityVerdict(
        wordCount: Int,
        profile: AudioProfile,
        baseline: Double,
        sentAudioSeconds: Double? = nil,
        localWordCount: Int? = nil,
        thresholds: DensityThresholds = .init()
    ) -> DensityVerdict {
        let minutes = profile.speechSeconds / 60
        let wpm = minutes > 0 ? Double(wordCount) / minutes : 0
        let ratio = baseline > 0 ? wpm / baseline : 0
        let half = profile.duration / 2
        let later = profile.speechSeconds > 0
            ? profile.speechSeconds(from: half, to: profile.duration) / profile.speechSeconds
            : 0
        var reason: String?
        let directOK = profile.speechSeconds >= thresholds.minSpeechSecondsForDirectSignals
        // A short recorded duration alone is not enough: some 2025 notes record
        // ~60 s for 4-minute files yet hold a complete-looking transcript.
        if directOK, let sent = sentAudioSeconds, sent > 0,
           sent < thresholds.maxSentAudioShare * profile.speechSeconds,
           baseline > 0, ratio < thresholds.maxRatioWithShortSentAudio {
            reason = "sent_audio_shorter"
        } else if let local = localWordCount, local >= thresholds.minLocalWords,
                  Double(wordCount) < thresholds.maxLocalWordShare * Double(local) {
            reason = "fewer_than_local"
        } else if minutes >= thresholds.minSpeechMinutes, baseline > 0, ratio < thresholds.maxRatio {
            reason = "sparse"
        }
        return DensityVerdict(
            isSuspect: reason != nil,
            reason: reason,
            wordsPerSpeechMinute: wpm,
            ratio: ratio,
            laterHalfSpeechShare: later,
            speechMinutes: minutes
        )
    }

    /// Median of the given words-per-speech-minute rates; 0 when empty.
    public static func baselineWordsPerSpeechMinute(_ rates: [Double]) -> Double {
        let sorted = rates.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }

    // MARK: 4. Model & word confidence (Parakeet TDT)

    public struct ConfidenceVerdict: Equatable, Sendable {
        public let isSuspect: Bool
        /// `low_confidence` (overall run confidence below threshold) or
        /// `low_word_confidence` (a large share of timed words have weak token probabilities).
        public let reason: String?
        public let mean: Double
        /// 10th-percentile word confidence (equals `mean` when per-word confidences are absent).
        public let p10: Double
        /// Share of timed words whose confidence is below `lowWordThreshold`.
        public let lowWordShare: Double

        public init(isSuspect: Bool, reason: String?, mean: Double, p10: Double, lowWordShare: Double) {
            self.isSuspect = isSuspect
            self.reason = reason
            self.mean = mean
            self.p10 = p10
            self.lowWordShare = lowWordShare
        }
    }

    public struct ConfidenceThresholds: Equatable, Sendable {
        /// Real speech in the 65-note bake-off never dropped below 0.79 mean confidence.
        public var minMeanConfidence: Double = 0.75
        /// Words below this softmax probability count toward `lowWordShare`.
        public var lowWordThreshold: Float = 0.60
        /// Flag `low_word_confidence` when `p10` is below this AND `lowWordShare` exceeds `maxLowWordShare`.
        public var minP10Confidence: Double = 0.55
        public var maxLowWordShare: Double = 0.25
        public var minWordsForWordStats: Int = 8
        public init() {}
    }

    public static func confidenceVerdict(
        confidence: Float,
        words: [SpeakerTurns.Word] = [],
        thresholds: ConfidenceThresholds = .init()
    ) -> ConfidenceVerdict {
        let mean = Double(max(0, min(1, confidence)))
        let wordConfidences = words.compactMap(\.confidence).filter(\.isFinite).map { max(0, min(1, $0)) }
        let p10: Double
        let lowShare: Double
        if !wordConfidences.isEmpty {
            let sorted = wordConfidences.sorted()
            let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.10).rounded(.down))))
            p10 = Double(sorted[idx])
            let lowCount = wordConfidences.filter { $0 < thresholds.lowWordThreshold }.count
            lowShare = Double(lowCount) / Double(wordConfidences.count)
        } else {
            p10 = mean
            lowShare = confidence < thresholds.lowWordThreshold ? 1.0 : 0.0
        }

        let reason: String?
        if mean < thresholds.minMeanConfidence {
            reason = "low_confidence"
        } else if wordConfidences.count >= thresholds.minWordsForWordStats,
                  p10 < thresholds.minP10Confidence,
                  lowShare > thresholds.maxLowWordShare {
            reason = "low_word_confidence"
        } else {
            reason = nil
        }
        return ConfidenceVerdict(
            isSuspect: reason != nil,
            reason: reason,
            mean: mean,
            p10: p10,
            lowWordShare: lowShare
        )
    }

    // MARK: 5. Time-aligned speech coverage (timed words vs AudioSilenceMap)

    public struct CoverageVerdict: Equatable, Sendable {
        public let isSuspect: Bool
        /// `unspoken_speech` when long stretches of detected speech contain no timed words.
        public let reason: String?
        /// Total speech seconds sitting inside wordless spans of at least `minGapSpeechSeconds`.
        public let unspokenSpeechSeconds: Double
        /// Longest single wordless span measured in speech seconds.
        public let maxUnspokenSpeechStretch: Double
        /// `unspokenSpeechSeconds / profile.speechSeconds` (0 when no speech).
        public let unspokenShare: Double
    }

    public struct CoverageThresholds: Equatable, Sendable {
        /// A wordless span must hold at least this many seconds of detected speech to count.
        public var minGapSpeechSeconds: Double = 10.0
        /// A single wordless stretch with at least this many speech seconds is suspect.
        public var maxSingleStretchSpeechSeconds: Double = 15.0
        /// Or total `unspokenSpeechSeconds` covering more than this share of detected speech.
        public var maxUnspokenShare: Double = 0.30
        public init() {}
    }

    public static func coverageVerdict(
        words: [SpeakerTurns.Word],
        profile: AudioProfile,
        thresholds: CoverageThresholds = .init()
    ) -> CoverageVerdict {
        let sorted = words.filter { $0.end > $0.start && $0.end > 0 }.sorted { $0.start < $1.start }
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for word in sorted {
            let start = max(0, min(profile.duration, word.start))
            if start > cursor {
                gaps.append((cursor, start))
            }
            cursor = max(cursor, min(profile.duration, word.end))
        }
        if profile.duration > cursor {
            gaps.append((cursor, profile.duration))
        }

        let gapSpeech = gaps.map { profile.speechSeconds(from: $0.0, to: $0.1) }
        let maxStretch = gapSpeech.max() ?? 0
        let unspoken = gapSpeech.filter { $0 >= thresholds.minGapSpeechSeconds }.reduce(0, +)
        let share = profile.speechSeconds > 0 ? unspoken / profile.speechSeconds : 0
        let isSuspect = maxStretch >= thresholds.maxSingleStretchSpeechSeconds
            || (unspoken >= thresholds.minGapSpeechSeconds && share > thresholds.maxUnspokenShare)
        return CoverageVerdict(
            isSuspect: isSuspect,
            reason: isSuspect ? "unspoken_speech" : nil,
            unspokenSpeechSeconds: unspoken,
            maxUnspokenSpeechStretch: maxStretch,
            unspokenShare: share
        )
    }

    // MARK: 6. Unified per-run quality report

    public struct QualityReport: Equatable, Sendable {
        /// Library median words per speech-minute from the 2026-10-24 full-library audit.
        public static let defaultBaselineWordsPerSpeechMinute: Double = 69.0

        public let wordCount: Int
        public let loop: LoopScore
        public let isLoop: Bool
        public let silence: SilenceVerdict?
        public let density: DensityVerdict?
        public let confidence: ConfidenceVerdict?
        public let coverage: CoverageVerdict?
        /// Machine-readable issue codes (e.g. `"loop:phrase"`, `"silence:near_silent"`,
        /// `"short:fewer_than_local"`, `"confidence:low_confidence"`, `"coverage:unspoken_speech"`).
        public let issues: [String]
        /// What was actually evaluated. Missing data must not masquerade as a passed check.
        public let checks: [String: String]

        public var isHealthy: Bool { issues.isEmpty && checks.values.allSatisfy { $0 == "checked" } }

        public var sidecarDictionary: [String: Any] {
            func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
            func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
            var dict: [String: Any] = [
                "schema": 2,
                "detectorVersion": "2026-10-27.1",
                "status": !issues.isEmpty ? "suspect" : (isHealthy ? "ok" : "unknown"),
                "checks": checks,
                "wordCount": wordCount,
                "repeated6GramShare": round3(loop.repeatedShare),
                "issues": issues,
            ]
            if isLoop, !loop.topPhrase.isEmpty {
                dict["topRepeatedPhrase"] = loop.topPhrase
                dict["topRepeatedCount"] = loop.topCount
            }
            if let c = confidence {
                dict["confidence"] = round3(c.mean)
                if checks["word_confidence"] == "checked" {
                    dict["p10Confidence"] = round3(c.p10)
                    dict["lowConfidenceWordShare"] = round3(c.lowWordShare)
                }
            }
            if let s = silence {
                dict["peakDBFS"] = round1(s.peakDBFS)
                dict["medianDBFS"] = round1(s.medianDBFS)
                dict["audibleSeconds"] = s.audibleSeconds
            }
            if let d = density, d.speechMinutes > 0 {
                dict["speechSeconds"] = round1(d.speechMinutes * 60)
                dict["wordsPerSpeechMinute"] = round1(d.wordsPerSpeechMinute)
            }
            if let cov = coverage {
                dict["unspokenSpeechSeconds"] = round1(cov.unspokenSpeechSeconds)
                dict["maxUnspokenSpeechStretch"] = round1(cov.maxUnspokenSpeechStretch)
            }
            return dict
        }
    }

    public static func evaluate(
        text: String,
        profile: AudioProfile? = nil,
        confidence: Float? = nil,
        timedWords: [SpeakerTurns.Word] = [],
        sentAudioSeconds: Double? = nil,
        localWordCount: Int? = nil,
        baselineWordsPerSpeechMinute: Double = QualityReport.defaultBaselineWordsPerSpeechMinute,
        loopShareThreshold: Double = 0.15
    ) -> QualityReport {
        let loop = loopScore(text)
        let isLoop = loop.repeatedShare > loopShareThreshold
        var issues: [String] = []
        if isLoop {
            issues.append("loop:\(loop.isPhraseLoop ? "phrase" : "passage")")
        }

        var silence: SilenceVerdict?
        var density: DensityVerdict?
        var coverage: CoverageVerdict?
        var checks = ["loop": "checked", "silence": "unavailable", "density": "unavailable",
                      "confidence": "unavailable", "word_confidence": "unavailable", "coverage": "unavailable"]

        if let profile {
            checks["silence"] = isLoop ? "skipped_loop" : "checked"
            checks["density"] = isLoop ? "skipped_loop" : "skipped_silence"
            if !isLoop {
                let s = silenceVerdict(wordCount: loop.wordCount, profile: profile)
                silence = s
                if s.isSuspect, let r = s.reason {
                    issues.append("silence:\(r)")
                } else {
                    let d = densityVerdict(
                        wordCount: loop.wordCount,
                        profile: profile,
                        baseline: baselineWordsPerSpeechMinute,
                        sentAudioSeconds: sentAudioSeconds,
                        localWordCount: localWordCount
                    )
                    density = d
                    checks["density"] = "checked"
                    if d.isSuspect, let r = d.reason {
                        issues.append("short:\(r)")
                    }
                }
            }
            if !timedWords.isEmpty {
                let cov = coverageVerdict(words: timedWords, profile: profile)
                coverage = cov
                checks["coverage"] = "checked"
                if cov.isSuspect, let r = cov.reason {
                    issues.append("coverage:\(r)")
                }
            }
        } else if !isLoop {
            let densityThresholds = DensityThresholds()
            if let local = localWordCount,
               local >= densityThresholds.minLocalWords,
               Double(loop.wordCount) < densityThresholds.maxLocalWordShare * Double(local) {
                let d = DensityVerdict(
                    isSuspect: true,
                    reason: "fewer_than_local",
                    wordsPerSpeechMinute: 0,
                    ratio: 0,
                    laterHalfSpeechShare: 0,
                    speechMinutes: 0
                )
                density = d
                checks["density"] = "checked"
                issues.append("short:fewer_than_local")
            }
        }

        var confVerdict: ConfidenceVerdict?
        if let confidence, confidence.isFinite {
            let c = confidenceVerdict(confidence: confidence, words: timedWords)
            confVerdict = c
            checks["confidence"] = "checked"
            checks["word_confidence"] = timedWords.compactMap(\.confidence).filter(\.isFinite).count >= ConfidenceThresholds().minWordsForWordStats
                ? "checked" : "insufficient_data"
            if c.isSuspect, let r = c.reason {
                issues.append("confidence:\(r)")
            }
        }

        return QualityReport(
            wordCount: loop.wordCount,
            loop: loop,
            isLoop: isLoop,
            silence: silence,
            density: density,
            confidence: confVerdict,
            coverage: coverage,
            issues: issues,
            checks: checks
        )
    }
}
