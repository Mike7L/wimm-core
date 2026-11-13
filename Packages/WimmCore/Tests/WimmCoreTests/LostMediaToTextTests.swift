import XCTest
import WimmDomain
@testable import WimmInfrastructure

/// `wimm-cli notes lost-to-text`: lost-media sidecars become `{base}.txt`,
/// dry run by default, apply only creates files.
final class LostMediaToTextTests: XCTestCase {
    var recordings: URL!

    override func setUp() {
        super.setUp()
        recordings = FileManager.default.temporaryDirectory
            .appendingPathComponent("lost-to-text-\(UUID().uuidString)/Recordings")
        try? FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: recordings.deletingLastPathComponent())
        super.tearDown()
    }

    private func sidecar(_ base: String, _ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: recordings.appendingPathComponent(base + ".meta.json"))
    }

    private func file(_ name: String, _ text: String = "x") throws {
        try text.write(to: recordings.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func snapshot() throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: recordings.path)
        return Dictionary(uniqueKeysWithValues: try names.map {
            ($0, try Data(contentsOf: recordings.appendingPathComponent($0)))
        })
    }

    private let lost = "Wimm_2026-01-14_09-12-03_ABCD1234"

    private func library() throws {
        // A lost audio note with a link pointing at it from a typed note.
        try sidecar(lost, ["transcription": ["transcript": " сказанное слово ", "audioDurationSec": 412.4],
                           "noteCard": ["title": "T"]])
        try file("Wimm_2026-01-15_10-00-00_EEEE0000.txt", "see [[\(lost)]] and [[\(lost).m4a|alias]]")
        // Normal note: media present.
        try sidecar("Wimm_2026-01-14_10-00-00_PRESENT0", ["transcription": ["transcript": "here"]])
        try file("Wimm_2026-01-14_10-00-00_PRESENT0.m4a")
        // Unknown duration, legacy iPhone string.
        try sidecar("Wimm_2026-01-14_11-00-00_LEGACY00", ["transcription": "iphone text"])
        // Apart: attach session, derived-only, non-Wimm name, no text, failure placeholder.
        try sidecar("Wimm_2026-01-14_12-00-00_ATTACH00", ["transcription": ["transcript": "t"]])
        try file("Wimm_2026-01-14_12-00-00_ATTACH00_Attach_1.jpg")
        try sidecar("Wimm_2026-01-14_13-00-00_MICRO000", ["transcription": ["transcript": "t"]])
        try file("Wimm_2026-01-14_13-00-00_MICRO000_micro.m4a")
        try sidecar("Scan 2020", ["transcription": ["transcript": "t"]])
        try sidecar("Wimm_2026-01-14_14-00-00_EMPTY000", ["transcription": ["transcript": "  "]])
        try sidecar("Wimm_2026-01-14_15-00-00_FAILED00", ["transcription": ["transcript": "Transcription failed (err: unknown)"]])
        // A screen grab's sidecar of a living note, holding an import failure placeholder.
        try file("Wimm_2026-01-14_16-00-00.m4a")
        try sidecar("Wimm_2026-01-14_16-00-00", ["transcription": ["transcript": "t"]])
        try sidecar("Wimm_2026-01-14_16-00-00_screen1", ["transcription": ["transcript": "Import transcription failed (decode: Failed to open PDF)",
                                                                           "audioDurationSec": 1]])
    }

    func testDryRunListsCandidatesAndGroupsAndWritesNothing() throws {
        try library()
        let before = try snapshot()
        let report = LostMediaToText.scan(recordings: recordings)
        XCTAssertEqual(try snapshot(), before, "a dry run writes nothing in the library")

        XCTAssertEqual(report.candidates.map(\.base), [lost, "Wimm_2026-01-14_11-00-00_LEGACY00"])
        let first = report.candidates[0]
        XCTAssertEqual(first.header, "[Расшифровка утраченной аудиозаписи · 6 мин 52 с · записано 2026-01-14 09:12]")
        XCTAssertEqual(first.words, 2)
        XCTAssertEqual(first.links, 2)
        XCTAssertEqual(first.fileText, first.header + "\n\nсказанное слово\n")
        XCTAssertEqual(report.candidates[1].header, "[Текст утраченного файла · записано 2026-01-14 11:00]")

        let reasons = Dictionary(grouping: report.skipped, by: \.reason).mapValues { $0.map(\.base) }
        XCTAssertEqual(reasons[.attachSession], ["Wimm_2026-01-14_12-00-00_ATTACH00"])
        XCTAssertEqual(reasons[.derivedAudioOnly], ["Wimm_2026-01-14_13-00-00_MICRO000"])
        XCTAssertEqual(reasons[.nonWimmName], ["Scan 2020"])
        XCTAssertEqual(reasons[.previewOfPresentNote], ["Wimm_2026-01-14_16-00-00_screen1"])
        XCTAssertTrue(LostMediaToText.isPlaceholder("Import transcription failed (decode: Failed to open PDF)"))
        XCTAssertEqual(Set(reasons[.noText] ?? []), ["Wimm_2026-01-14_14-00-00_EMPTY000", "Wimm_2026-01-14_15-00-00_FAILED00"])

        let markdown = LostMediaToText.markdown(report, applied: false, library: recordings)
        XCTAssertTrue(markdown.contains("2 notes, 4 words"), markdown)
        XCTAssertTrue(markdown.contains("## Not converted: attach-session (1)"), markdown)
    }

    func testApplyCreatesOnlyTextFilesAndNeverOverwrites() throws {
        try library()
        let report = LostMediaToText.scan(recordings: recordings)
        // A file appears for the second candidate between the dry run and the apply.
        try file("Wimm_2026-01-14_11-00-00_LEGACY00.txt", "typed by hand")
        let before = try snapshot()

        let applied = LostMediaToText.apply(report, recordings: recordings)
        XCTAssertEqual(applied.created.map(\.lastPathComponent), [lost + ".txt"])
        XCTAssertEqual(applied.refused, ["Wimm_2026-01-14_11-00-00_LEGACY00"])

        let after = try snapshot()
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), [lost + ".txt"], "only the new file")
        for (name, data) in before { XCTAssertEqual(after[name], data, "\(name) untouched (sidecars included)") }
        XCTAssertEqual(String(decoding: after[lost + ".txt"]!, as: UTF8.self),
                       report.candidates[0].fileText)

        // Its "updated" time stays the sidecar's: a pass does not see it as changed.
        let created = recordings.appendingPathComponent(lost + ".txt")
        func modified(_ url: URL) throws -> Date? { try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        let sidecarModified = try XCTUnwrap(try modified(recordings.appendingPathComponent(lost + ".meta.json")))
        XCTAssertLessThanOrEqual(try XCTUnwrap(try modified(created)), sidecarModified)

        // The new file is an ordinary text note: the file is the body, the old sidecar stays its sidecar.
        let content = NoteContent.load(anchor: recordings.appendingPathComponent(lost + ".txt"),
                                       sidecar: [:])
        XCTAssertEqual(content.kind, .text)
        XCTAssertTrue(content.body?.hasPrefix("[Расшифровка утраченной аудиозаписи") == true)

        // Re-run: the converted note is no longer a candidate; nothing new is written.
        let again = LostMediaToText.scan(recordings: recordings)
        XCTAssertFalse(again.candidates.contains { $0.base == lost })
        XCTAssertTrue(LostMediaToText.apply(again, recordings: recordings).created.isEmpty)
    }

    func testDurationWording() {
        XCTAssertEqual(LostMediaToText.duration(42), "42 с")
        XCTAssertEqual(LostMediaToText.duration(412.4), "6 мин 52 с")
        XCTAssertEqual(LostMediaToText.duration(3900), "1 ч 5 мин")
        XCTAssertEqual(LostMediaToText.duration(7200), "2 ч")
    }
}
