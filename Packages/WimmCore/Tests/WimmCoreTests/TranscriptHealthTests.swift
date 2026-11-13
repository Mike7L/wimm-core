import XCTest
import WimmInfrastructure

final class TranscriptHealthTests: XCTestCase {

    // MARK: Loops

    func testPhraseLoopScoresHigh() {
        let text = "Мы начали разговор про отпуск. " + String(repeating: "Я не помню. ", count: 200)
        let score = TranscriptHealth.loopScore(text)
        XCTAssertGreaterThan(score.repeatedShare, 0.9)
        XCTAssertTrue(score.isPhraseLoop)
        XCTAssertTrue(score.topPhrase.contains("я не помню"))
    }

    func testOrdinarySpeechScoresLow() {
        let text = """
        Сегодня утром я поехал в город, купил хлеба и молока, потом встретил соседа, \
        который рассказал про ремонт дороги. Мы договорились зайти вечером, обсудить, \
        что делать с забором, и заодно посмотреть, как растут яблони в саду. Потом я \
        вернулся домой, позвонил маме, спросил про здоровье и записал список дел на завтра.
        """
        let score = TranscriptHealth.loopScore(text)
        XCTAssertLessThan(score.repeatedShare, 0.05)
        XCTAssertFalse(score.isPhraseLoop)
    }

    func testDuplicatedPassageIsRepeatedButNotAPhraseLoop() {
        let passage = """
        ты придуриваешься у тебя ничего не болит ты лежишь и придуриваешься если что-то \
        болит то это не повод сидеть дома весь день и ничего не делать вообще
        """
        let text = "вступление про утро и про погоду за окном " + passage + " " + passage + " и потом мы пошли гулять"
        let score = TranscriptHealth.loopScore(text)
        XCTAssertGreaterThan(score.repeatedShare, 0.15)
        XCTAssertFalse(score.isPhraseLoop)
    }

    func testShortTextIsNeverALoop() {
        XCTAssertEqual(TranscriptHealth.loopScore("да да да да да да да да да").repeatedShare, 0)
    }

    func testTokensFoldYoAndCase() {
        XCTAssertEqual(TranscriptHealth.words("Ещё, ЕЩЕ!"), ["еще", "еще"])
    }

    // MARK: Profile

    private func profile(secondRMS: [Float]) -> TranscriptHealth.AudioProfile {
        // 0.2 s windows, five per second, all at the second's level.
        TranscriptHealth.profile(windowRMS: secondRMS.flatMap { Array(repeating: $0, count: 5) }, windowSeconds: 0.2)
    }

    func testProfileAggregatesSecondsAndSpeech() {
        let p = profile(secondRMS: Array(repeating: 0.0001, count: 30) + Array(repeating: 0.05, count: 30))
        XCTAssertEqual(p.secondRMS.count, 60)
        XCTAssertEqual(p.duration, 60, accuracy: 0.001)
        XCTAssertEqual(p.secondRMS[45], 0.05, accuracy: 0.0001)
        XCTAssertEqual(p.speechSeconds, 30.3, accuracy: 0.5)
        XCTAssertGreaterThan(p.speechSeconds(from: 30, to: 60), 29)
    }

    // MARK: Text on silence

    func testTextOverNearSilenceIsSuspect() {
        // The 560B19E3 shape: median ≈ −79 dBFS, peak right at the gate (−49 dBFS).
        var seconds = Array(repeating: Float(0.000112), count: 196)
        seconds[100] = 0.00355
        let verdict = TranscriptHealth.silenceVerdict(wordCount: 60, profile: profile(secondRMS: seconds))
        XCTAssertTrue(verdict.isSuspect)
        XCTAssertEqual(verdict.reason, "near_silent")
        XCTAssertEqual(verdict.medianDBFS, -79, accuracy: 1)
        XCTAssertEqual(verdict.peakDBFS, -49, accuracy: 1)
    }

    func testTextBelowGateIsSuspect() {
        let verdict = TranscriptHealth.silenceVerdict(
            wordCount: 20,
            profile: profile(secondRMS: Array(repeating: 0.001, count: 60))
        )
        XCTAssertEqual(verdict.reason, "silent")
    }

    func testQuietDictationJustUnderTheGateIsNotSuspect() {
        // Library shape: coherent night dictation, peak −50 dBFS, median −62 dBFS.
        let seconds = (0..<180).map { $0 % 4 == 0 ? Float(0.0031) : Float(0.0008) }
        let verdict = TranscriptHealth.silenceVerdict(wordCount: 228, profile: profile(secondRMS: seconds))
        XCTAssertFalse(verdict.isSuspect, verdict.reason ?? "")
    }

    func testMoreWordsThanSpeechIsSuspect() {
        // Two seconds of sound cannot hold 200 words.
        var seconds = Array(repeating: Float(0.002), count: 120)
        seconds[10] = 0.05
        seconds[11] = 0.05
        let verdict = TranscriptHealth.silenceVerdict(wordCount: 200, profile: profile(secondRMS: seconds))
        XCTAssertEqual(verdict.reason, "more_words_than_speech")
        XCTAssertEqual(verdict.audibleSeconds, 2)
    }

    func testQuietButRealSpeechIsNotSuspect() {
        // Quiet room speech: peak −36 dBFS, median −55 dBFS, sensible word count.
        let seconds = (0..<120).map { $0 % 3 == 0 ? Float(0.016) : Float(0.0018) }
        let verdict = TranscriptHealth.silenceVerdict(wordCount: 150, profile: profile(secondRMS: seconds))
        XCTAssertFalse(verdict.isSuspect)
    }

    // MARK: Truncation

    func testSparseTranscriptOfLongSpeechIsSuspect() {
        // 20 min of speech, the library writes ~110 words/min, transcript has 600.
        let p = profile(secondRMS: Array(repeating: 0.05, count: 1200))
        let verdict = TranscriptHealth.densityVerdict(wordCount: 600, profile: p, baseline: 110)
        XCTAssertEqual(verdict.reason, "sparse")
        XCTAssertEqual(verdict.wordsPerSpeechMinute, 30, accuracy: 1)
        XCTAssertEqual(verdict.laterHalfSpeechShare, 0.5, accuracy: 0.01)
    }

    func testNormalDensityIsNotSuspect() {
        let p = profile(secondRMS: Array(repeating: 0.05, count: 1200))
        XCTAssertFalse(TranscriptHealth.densityVerdict(wordCount: 2000, profile: p, baseline: 110).isSuspect)
    }

    func testShortRecordingIsNotJudged() {
        let p = profile(secondRMS: Array(repeating: 0.05, count: 120))
        XCTAssertFalse(TranscriptHealth.densityVerdict(wordCount: 10, profile: p, baseline: 110).isSuspect)
    }

    func testTranscriberGotShorterAudioThanTheSpeech() {
        // The 787C30CA shape: 34 min of speech, the transcriber recorded 10 s.
        let p = profile(secondRMS: Array(repeating: 0.05, count: 2000))
        let verdict = TranscriptHealth.densityVerdict(wordCount: 2, profile: p, baseline: 70, sentAudioSeconds: 10)
        XCTAssertEqual(verdict.reason, "sent_audio_shorter")
        // A short recorded duration over a normal-density transcript is not evidence.
        XCTAssertFalse(TranscriptHealth.densityVerdict(
            wordCount: 2000, profile: p, baseline: 70, sentAudioSeconds: 60
        ).isSuspect)
        // A silence-trimmed upload close to the speech length is fine.
        XCTAssertFalse(TranscriptHealth.densityVerdict(
            wordCount: 2400, profile: p, baseline: 70, sentAudioSeconds: 1900
        ).isSuspect)
    }

    func testFewerWordsThanLocalTranscript() {
        let p = profile(secondRMS: Array(repeating: 0.05, count: 180))
        let verdict = TranscriptHealth.densityVerdict(wordCount: 40, profile: p, baseline: 70, localWordCount: 300)
        XCTAssertEqual(verdict.reason, "fewer_than_local")
        XCTAssertFalse(TranscriptHealth.densityVerdict(
            wordCount: 280, profile: p, baseline: 70, localWordCount: 300
        ).isSuspect)
    }

    func testBaselineIsMedianOfPositiveRates() {
        XCTAssertEqual(TranscriptHealth.baselineWordsPerSpeechMinute([0, 90, 110, 130]), 110)
        XCTAssertEqual(TranscriptHealth.baselineWordsPerSpeechMinute([]), 0)
    }

    // MARK: Parakeet token-to-word confidence & coverage

    func testParakeetTimedWordsAggregatesSubwordConfidences() {
        let tokens: [ParakeetModel.TimedToken] = [
            .init(token: "▁бабу", startTime: 0.10, endTime: 0.30, confidence: 0.90),
            .init(token: "лень", startTime: 0.30, endTime: 0.50, confidence: 0.80),
            .init(token: "ка", startTime: 0.50, endTime: 0.70, confidence: 0.70),
            .init(token: "<blank>", startTime: 0.70, endTime: 0.80, confidence: 1.00),
            .init(token: "▁привет", startTime: 0.80, endTime: 1.20, confidence: 0.95),
        ]
        let words = ParakeetModel.timedWords(from: tokens)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].text, "бабуленька")
        XCTAssertEqual(words[0].start, 0.10, accuracy: 0.001)
        XCTAssertEqual(words[0].end, 0.70, accuracy: 0.001)
        XCTAssertEqual(Double(words[0].confidence ?? 0), 0.80, accuracy: 0.001)
        XCTAssertEqual(words[1].text, "привет")
        XCTAssertEqual(Double(words[1].confidence ?? 0), 0.95, accuracy: 0.001)
    }

    func testConfidenceVerdictDetectsLowOverallAndLowWordTail() {
        let healthyWords = (0..<10).map { i in
            SpeakerTurns.Word(text: "w\(i)", start: Double(i), end: Double(i) + 0.5, confidence: 0.90)
        }
        let ok = TranscriptHealth.confidenceVerdict(confidence: 0.90, words: healthyWords)
        XCTAssertFalse(ok.isSuspect)
        XCTAssertNil(ok.reason)
        XCTAssertEqual(ok.p10, 0.90, accuracy: 0.01)
        XCTAssertEqual(ok.lowWordShare, 0, accuracy: 0.01)

        let lowOverall = TranscriptHealth.confidenceVerdict(confidence: 0.68, words: healthyWords)
        XCTAssertTrue(lowOverall.isSuspect)
        XCTAssertEqual(lowOverall.reason, "low_confidence")

        // Acceptable mean (0.76), but 4 of 10 words have very weak confidence (0.40).
        let noisyTailWords = (0..<10).map { i in
            SpeakerTurns.Word(
                text: "w\(i)",
                start: Double(i),
                end: Double(i) + 0.5,
                confidence: i < 4 ? 0.40 : 0.98
            )
        }
        let noisy = TranscriptHealth.confidenceVerdict(confidence: 0.76, words: noisyTailWords)
        XCTAssertTrue(noisy.isSuspect)
        XCTAssertEqual(noisy.reason, "low_word_confidence")
        XCTAssertEqual(noisy.p10, 0.40, accuracy: 0.01)
        XCTAssertEqual(noisy.lowWordShare, 0.40, accuracy: 0.01)
    }

    func testCoverageVerdictFlagsDroppedSpeechTail() {
        // 60 seconds of active speech; words only cover the first 35 seconds, leaving a 25 s unspoken tail.
        let p = profile(secondRMS: Array(repeating: 0.05, count: 60))
        let words = stride(from: 0.0, to: 35.0, by: 2.0).map { t in
            SpeakerTurns.Word(text: "слово", start: t, end: t + 1.0, confidence: 0.92)
        }
        let dropped = TranscriptHealth.coverageVerdict(words: words, profile: p)
        XCTAssertTrue(dropped.isSuspect)
        XCTAssertEqual(dropped.reason, "unspoken_speech")
        XCTAssertEqual(dropped.maxUnspokenSpeechStretch, 26.0, accuracy: 1.0)

        let coveredWords = stride(from: 0.0, to: 58.0, by: 2.0).map { t in
            SpeakerTurns.Word(text: "слово", start: t, end: t + 1.0, confidence: 0.92)
        }
        let full = TranscriptHealth.coverageVerdict(words: coveredWords, profile: p)
        XCTAssertFalse(full.isSuspect)
        XCTAssertEqual(full.unspokenSpeechSeconds, 0, accuracy: 0.1)
    }

    func testEvaluateProducesUnifiedQualityReport() {
        let p = profile(secondRMS: Array(repeating: 0.05, count: 60))
        let words = stride(from: 0.0, to: 30.0, by: 3.0).map { t in
            SpeakerTurns.Word(text: "слово", start: t, end: t + 1.0, confidence: 0.65)
        }
        let report = TranscriptHealth.evaluate(
            text: Array(repeating: "разные слова в заметке", count: 5).joined(separator: " "),
            profile: p,
            confidence: 0.68,
            timedWords: words
        )
        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains("coverage:unspoken_speech"))
        XCTAssertTrue(report.issues.contains("confidence:low_confidence"))
        let dict = report.sidecarDictionary
        XCTAssertEqual(dict["status"] as? String, "suspect")
        XCTAssertEqual(dict["confidence"] as? Double, 0.68)
    }
    func testMissingQualityChecksAreUnknownInsteadOfHealthy() {
        let report = TranscriptHealth.evaluate(text: "Понятная короткая фраза")
        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertFalse(report.isHealthy)
        let value = report.sidecarDictionary
        XCTAssertEqual(value["status"] as? String, "unknown")
        let checks = value["checks"] as? [String: String]
        XCTAssertEqual(checks?["loop"], "checked")
        XCTAssertEqual(checks?["silence"], "unavailable")
        XCTAssertEqual(checks?["confidence"], "unavailable")
        XCTAssertEqual(checks?["coverage"], "unavailable")
        XCTAssertEqual(value["schema"] as? Int, 2)
        let meanOnly = TranscriptHealth.evaluate(text: "Понятная фраза", confidence: 0.99)
        XCTAssertEqual(meanOnly.checks["word_confidence"], "insufficient_data")
        XCTAssertNil(meanOnly.sidecarDictionary["p10Confidence"])
        XCTAssertNil(meanOnly.sidecarDictionary["lowConfidenceWordShare"])
        XCTAssertFalse(meanOnly.isHealthy, "high average confidence cannot stand in for missing checks")
    }

    func testCompleteDiagnosticsRecordCheckedStatusWithoutChangingThresholds() {
        let p = profile(secondRMS: Array(repeating: 0.05, count: 60))
        let words = (0..<60).map { i in
            SpeakerTurns.Word(text: "слово\(i)", start: Double(i), end: Double(i) + 0.8, confidence: 0.95)
        }
        let report = TranscriptHealth.evaluate(text: words.map(\.text).joined(separator: " "),
            profile: p, confidence: 0.95, timedWords: words)
        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.sidecarDictionary["status"] as? String, "ok")
        XCTAssertTrue(report.checks.values.allSatisfy { $0 == "checked" })
    }

}
