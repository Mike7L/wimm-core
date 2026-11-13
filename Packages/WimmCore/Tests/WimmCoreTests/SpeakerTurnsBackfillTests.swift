import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// The speaker split after a Parakeet run is detached; when it never lands (process killed,
/// diarizer failed) `SpeakerTurnsBackfill` must catch it up — and never write it over a
/// transcript that replaced the one it split.
final class SpeakerTurnsBackfillTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", tempDir.path, 1)
    }

    override func tearDown() {
        SpeakerTurnsBackfill.backgroundTimeHolder = nil
        unsetenv("WIMM_BASE_DIR")
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private let text = "Привет бабушка Здравствуй внучек"
    private let words = [
        SpeakerTurns.Word(text: "Привет", start: 0, end: 0.5),
        SpeakerTurns.Word(text: "бабушка", start: 0.6, end: 1.2),
        SpeakerTurns.Word(text: "Здравствуй", start: 2.0, end: 2.8),
        SpeakerTurns.Word(text: "внучек", start: 2.9, end: 3.4),
    ]
    private var twoSpeakers: SpeakerTurnsRecord {
        SpeakerTurnsRecord(speakers: 2, engine: "test", turns: SpeakerTurns.turns(words: words, spans: [
            SpeakerTurns.Span(speaker: "A", start: 0, end: 1.5),
            SpeakerTurns.Span(speaker: "B", start: 1.8, end: 3.6),
        ]))
    }

    /// A note as `TranscriptionService` leaves it when the detached split was killed:
    /// a Parakeet transcript and no `speakerTurns`.
    private func parakeetNote(_ name: String = "Wimm_2026-10-25_10-00-00_AAAA.m4a",
                              text: String? = nil, seconds: Double = 45) throws -> URL {
        let file = tempDir.appendingPathComponent(name)
        try Data().write(to: file)
        recordRunSuccess(file: file, provider: "parakeet", model: "ultra", audioDuration: seconds,
                         startedAt: Date(), elapsedSeconds: 0.5, transcript: text ?? self.text,
                         speechStatus: .speech, rawResponse: nil)
        return file
    }

    private func transcription(_ file: URL) -> [String: Any] {
        let data = (try? Data(contentsOf: FileStore.metadataURL(forRecordingURL: file))) ?? Data()
        let sidecar = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return sidecar["transcription"] as? [String: Any] ?? [:]
    }

    private func reads(_ text: String, seconds: Double = 45) -> SpeakerTurnsBackfill.Transcribe {
        let words = self.words
        return { _, _, _ in ParakeetTranscript(text: text, confidence: 0.95, audioSeconds: seconds, timedWords: words) }
    }

    func testKilledSplitIsCaughtUpAndStored() async throws {
        let file = try parakeetNote()
        let pending = SpeakerTurnsBackfill.candidates(in: tempDir)
        XCTAssertEqual(pending.map(\.audio.lastPathComponent), [file.lastPathComponent])
        XCTAssertEqual(pending.first?.model, "parakeet:ultra")

        let record = twoSpeakers
        let outcome = await SpeakerTurnsBackfill.run(
            pending[0], languages: ["ru"], apply: true, transcribe: reads(text), diarize: { _, _ in record })

        XCTAssertEqual(outcome, .stored(speakers: 2))
        let stored = SpeakerTurnsRecord(sidecarValue: transcription(file)[SpeakerTurnsRecord.sidecarKey])
        XCTAssertEqual(stored?.turns.map(\.text), ["Привет бабушка", "Здравствуй внучек"])
        XCTAssertEqual(transcription(file)["transcript"] as? String, text)
        XCTAssertTrue(SpeakerTurnsBackfill.candidates(in: tempDir).isEmpty, "a split note is done")
    }

    func testNeverWritesOverATranscriptThatReplacedTheSplitOne() async throws {
        let file = try parakeetNote()
        let candidate = try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file))
        let record = twoSpeakers
        let outcome = await SpeakerTurnsBackfill.run(
            candidate, languages: ["ru"], apply: true, transcribe: reads(text),
            diarize: { file, _ in
                // A new transcription lands while the diarizer runs.
                recordRunSuccess(file: file, provider: "gemini", model: "gemini-3-flash", audioDuration: 45,
                                 startedAt: Date(), elapsedSeconds: 1, transcript: "Совсем другой текст",
                                 speechStatus: .speech, rawResponse: nil)
                return record
            })

        XCTAssertEqual(outcome, .transcriptChanged)
        XCTAssertNil(transcription(file)[SpeakerTurnsRecord.sidecarKey])
        XCTAssertEqual(transcription(file)["transcript"] as? String, "Совсем другой текст")
    }

    func testLiveSplitOfAnOldTranscriptIsDropped() throws {
        let file = try parakeetNote()
        recordRunSuccess(file: file, provider: "parakeet", model: "ultra", audioDuration: 45,
                         startedAt: Date(), elapsedSeconds: 0.5, transcript: "Новый прогон",
                         speechStatus: .speech, rawResponse: nil)
        XCTAssertFalse(SpeakerTurnsBackfill.store(twoSpeakers, for: file, ifTranscriptIs: text))
        XCTAssertNil(transcription(file)[SpeakerTurnsRecord.sidecarKey])
    }

    func testDifferentReReadIsNotStoredAndNotRetriedUntilTheTranscriptChanges() async throws {
        let file = try parakeetNote()
        let candidate = try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file))
        let outcome = await SpeakerTurnsBackfill.run(
            candidate, languages: ["ru"], apply: true, transcribe: reads("Привет бабушка"),
            diarize: { _, _ in XCTFail("must not diarize words of another text"); throw CancellationError() })

        XCTAssertEqual(outcome, .textMismatch)
        XCTAssertNil(transcription(file)[SpeakerTurnsRecord.sidecarKey])
        XCTAssertNil(SpeakerTurnsBackfill.candidate(for: file), "the same text is not re-read on every pass")

        recordRunSuccess(file: file, provider: "parakeet", model: "ultra", audioDuration: 45,
                         startedAt: Date(), elapsedSeconds: 0.5, transcript: "Привет бабушка",
                         speechStatus: .speech, rawResponse: nil)
        XCTAssertNotNil(SpeakerTurnsBackfill.candidate(for: file), "a new transcript is a candidate again")
        XCTAssertNil(transcription(file)[SpeakerTurnsBackfill.skipKey], "a new run clears the marker")
    }

    func testFailedSplitIsRetriedAFewTimesButACancelledOneAlways() async throws {
        let file = try parakeetNote()
        struct Boom: Error {}
        for _ in 0..<3 {
            _ = await SpeakerTurnsBackfill.run(
                try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file)), languages: ["ru"], apply: true,
                transcribe: reads(text), diarize: { _, _ in throw CancellationError() })
        }
        XCTAssertNotNil(SpeakerTurnsBackfill.candidate(for: file), "a killed split counts nothing")

        for attempt in 1...SpeakerTurnsBackfill.maxFailedAttempts {
            let candidate = try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file), "attempt \(attempt)")
            let outcome = await SpeakerTurnsBackfill.run(
                candidate, languages: ["ru"], apply: true, transcribe: reads(text), diarize: { _, _ in throw Boom() })
            guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        }
        XCTAssertNil(SpeakerTurnsBackfill.candidate(for: file))
    }

    func testDryRunWritesNothing() async throws {
        let file = try parakeetNote()
        let before = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: file))
        let record = twoSpeakers
        let outcome = await SpeakerTurnsBackfill.run(
            try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file)), languages: ["ru"], apply: false,
            transcribe: reads(text), diarize: { _, _ in record })
        XCTAssertEqual(outcome, .wouldStore(speakers: 2))
        XCTAssertEqual(try Data(contentsOf: FileStore.metadataURL(forRecordingURL: file)), before)
    }

    func testOnlyLongSpeechParakeetNotesWithoutASplitAreCandidates() throws {
        _ = try parakeetNote("short.m4a", seconds: 10)
        let cloud = tempDir.appendingPathComponent("cloud.m4a")
        try Data().write(to: cloud)
        recordRunSuccess(file: cloud, provider: "gemini", model: "gemini-3-flash", audioDuration: 60,
                         startedAt: Date(), elapsedSeconds: 1, transcript: text, speechStatus: .speech, rawResponse: nil)
        let silent = try parakeetNote("silent.m4a")
        FileStore.upsertTranscriptionFields(for: silent, updates: ["speechStatus": TranscriptionSpeechStatus.noSpeech.rawValue])
        let split = try parakeetNote("split.m4a")
        SpeakerTurnsBackfill.store(twoSpeakers, for: split, ifTranscriptIs: text)
        let wanted = try parakeetNote("wanted.m4a")
        try Data().write(to: tempDir.appendingPathComponent("wanted_micro.m4a"))

        XCTAssertEqual(SpeakerTurnsBackfill.candidates(in: tempDir).map(\.audio.lastPathComponent), [wanted.lastPathComponent])
    }

    // MARK: - Background time (the iPhone's beginBackgroundTask)

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _expire: (@Sendable () -> Void)?
        var events: [String] { lock.lock(); defer { lock.unlock() }; return _events }
        func note(_ event: String) { lock.lock(); _events.append(event); lock.unlock() }
        func setExpire(_ expire: @escaping @Sendable () -> Void) { lock.lock(); _expire = expire; lock.unlock() }
        func expire() { lock.lock(); let e = _expire; lock.unlock(); note("expired"); e?() }

        func install(expireAtOnce: Bool = false) {
            SpeakerTurnsBackfill.backgroundTimeHolder = { name, expired in
                self.note("begin \(name)")
                self.setExpire(expired)
                if expireAtOnce { self.expire() }
                return { self.note("end") }
            }
        }
    }

    func testSplitHoldsBackgroundTimeUntilItIsWritten() async throws {
        let file = try parakeetNote()
        let holder = Holder()
        holder.install()
        let candidate = try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file))
        let record = twoSpeakers
        let transcribe = reads(text)
        await SpeakerTurnsBackfill.withBackgroundTime("split") {
            holder.note("work")
            _ = await SpeakerTurnsBackfill.run(candidate, languages: ["ru"], apply: true,
                                               transcribe: transcribe, diarize: { _, _ in record })
        }
        XCTAssertEqual(holder.events, ["begin split", "work", "end"])
        XCTAssertNotNil(transcription(file)[SpeakerTurnsRecord.sidecarKey])
    }

    func testSplitThatFinishesAsTimeRunsOutIsStillWritten() async throws {
        let file = try parakeetNote()
        let holder = Holder()
        holder.install()
        let candidate = try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file))
        let record = twoSpeakers
        let transcribe = reads(text)
        let outcome = OutcomeBox()
        await SpeakerTurnsBackfill.withBackgroundTime("split") {
            outcome.value = await SpeakerTurnsBackfill.run(
                candidate, languages: ["ru"], apply: true, transcribe: transcribe,
                diarize: { _, _ in holder.expire(); return record })
        }
        XCTAssertEqual(outcome.value, .stored(speakers: 2), "a computed split is never thrown away")
        XCTAssertEqual(holder.events.last, "end")
    }

    func testSplitCutOffBeforeItRunsCountsNothingAndStaysACandidate() async throws {
        let file = try parakeetNote()
        let holder = Holder()
        holder.install(expireAtOnce: true)
        let candidate = try XCTUnwrap(SpeakerTurnsBackfill.candidate(for: file))
        let record = twoSpeakers
        let transcribe = reads(text)
        await SpeakerTurnsBackfill.withBackgroundTime("split") {
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await SpeakerTurnsBackfill.run(candidate, languages: ["ru"], apply: true,
                                               transcribe: transcribe, diarize: { _, _ in record })
        }
        XCTAssertNil(transcription(file)[SpeakerTurnsRecord.sidecarKey])
        XCTAssertNil(transcription(file)[SpeakerTurnsBackfill.skipKey], "a cut-off split is not a failure")
        XCTAssertNotNil(SpeakerTurnsBackfill.candidate(for: file))
    }

    private final class OutcomeBox: @unchecked Sendable {
        var value: SpeakerTurnsBackfill.Outcome?
    }
}
