import Foundation
import XCTest
import WimmDomain
@testable import WimmInfrastructure
@testable import WimmSecretary

/// Packet preparation at library scale on invented data. Opt-in:
/// `WIMM_PREPARE_BENCH=1` (notes: `WIMM_PREPARE_BENCH_NOTES`, default 8000).
final class SecretaryPrepareBenchmarkTests: XCTestCase {
    private var root: URL!
    private var previousBase: String?
    /// `WIMM_PREPARE_BENCH_KEEP=<empty dir>`: write the fixture there and stop, for timing a release `WimmCLI`.
    private var keepFixture = false

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WIMM_PREPARE_BENCH"] == "1", "Set WIMM_PREPARE_BENCH=1")
        previousBase = ProcessInfo.processInfo.environment["WIMM_BASE_DIR"]
        if let keep = ProcessInfo.processInfo.environment["WIMM_PREPARE_BENCH_KEEP"], !keep.isEmpty {
            root = URL(fileURLWithPath: keep).resolvingSymlinksInPath()
            keepFixture = true
        } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("prepare-bench-\(UUID().uuidString)").resolvingSymlinksInPath()
        }
        setenv("WIMM_BASE_DIR", root.path, 1)
    }

    override func tearDown() {
        guard root != nil else { return }
        if let previousBase { setenv("WIMM_BASE_DIR", previousBase, 1) } else { unsetenv("WIMM_BASE_DIR") }
        if !keepFixture { try? FileManager.default.removeItem(at: root) }
    }

    func testPrepareAtLibraryScale() async throws {
        let count = Int(ProcessInfo.processInfo.environment["WIMM_PREPARE_BENCH_NOTES"] ?? "") ?? 8000
        let fresh = 40
        let scale = Int(ProcessInfo.processInfo.environment["WIMM_PREPARE_BENCH_SCALE"] ?? "") ?? 1
        let recordings = root.appendingPathComponent("Recordings")
        let workspace = root.appendingPathComponent("ws")
        for path in ["docs", "secretary/protocol"] {
            try FileManager.default.createDirectory(at: workspace.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("recordings"), withDestinationURL: recordings)
        let marks = AgentMarkStore(directory: root.appendingPathComponent("AgentState"))

        let words = ["маяк", "лодка", "сад", "письмо", "поезд", "город", "мост", "ремонт", "встреча", "план",
                     "озеро", "книга", "рынок", "врач", "школа", "дорога", "чай", "окно", "Ёж", "ветер"]
        let start = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var rows: [[String: Any]] = [], newMarks: [String: AgentMarkStore.Mark?] = [:]
        var files: [URL] = []
        let clock = Date()
        for i in 0..<count {
            let date = start.addingTimeInterval(Double(i) * 2_100)
            let file = recordings.appendingPathComponent("Wimm_\(formatter.string(from: date)).txt")
            var text = "Заметка \(i). "
            for j in 0..<((200 + (i % 7) * 60) * scale) { text += words[(i * 31 + j * 7) % words.count] + (j % 12 == 11 ? ". " : " ") }
            try text.write(to: file, atomically: true, encoding: .utf8)
            let sidecar = FileStore.metadataURL(forRecordingURL: file)
            try FileStore.mutateSidecar(at: sidecar) { $0["recordingId"] = "note-\(i)"; return true }
            files.append(file)
            guard i < count - fresh else { continue }
            for url in [file, sidecar] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path) }
            rows.append(["source_id": "S\(i + 1)", "path": "../recordings/\(sidecar.lastPathComponent)",
                         "note_file": file.lastPathComponent, "status": "applied", "reason": "built in", "primary_text_read": true])
            let fp = NoteFingerprint.read(forRecordingURL: file)
            newMarks[file.lastPathComponent] = .init(status: .applied, source: "S\(i + 1)", markedAt: date,
                                                     noteId: "note-\(i)", text: fp.text, analysis: fp.analysis)
        }
        try marks.update(newMarks)
        try marks.setPass(.init(asOf: clock.addingTimeInterval(-3_600), cursor: nil, comment: nil, setAt: clock))

        var document = "# Личный документ\n\n"
        let sections = max(1, count / 25)
        for s in 0..<sections {
            document += "## Тема \(s): \(words[s % words.count])\n\n**Состояние на 2026-11-01:** идёт.\n\n"
            for p in 0..<10 {
                let source = (s * 10 + p) % max(1, rows.count) + 1
                document += "Абзац \(p) про \(words[(s + p) % words.count]) и \(words[(s * 3 + p) % words.count]), план не факт [S\(source)].\n\n"
            }
        }
        for row in rows { document += "[\(row["source_id"]!)]: \(row["path"]!)\n" }
        let documentURL = workspace.appendingPathComponent("docs/me.md")
        try document.write(to: documentURL, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["sources": rows, "source_count": rows.count, "counts": ["applied": rows.count], "batches": []])
            .write(to: documentURL.deletingPathExtension().appendingPathExtension("sources.json"))
        try "Сохранять все варианты и различать планы и факты.".write(to: workspace.appendingPathComponent("secretary/protocol/packet.md"), atomically: true, encoding: .utf8)
        try "## Открытые вопросы\n\nНет.\n".write(to: workspace.appendingPathComponent("secretary/review_queue.md"), atomically: true, encoding: .utf8)
        print("BENCH setup: \(count) notes, document \(document.utf8.count / 1000) KB, registry \(rows.count) rows")
        if keepFixture { print("BENCH fixture: \(documentURL.path)"); return }

        let cache = marks.directory.appendingPathComponent("SecretaryRecallCache")
        var t = Date()
        _ = await LibraryRecallSource(includeFingerprints: true, cacheDirectory: cache).load()
        print("BENCH cold library build: \(Int(Date().timeIntervalSince(t) * 1000)) ms"); fflush(stdout)

        for run in 1...(Int(ProcessInfo.processInfo.environment["WIMM_PREPARE_BENCH_RUNS"] ?? "") ?? 3) {
            t = Date()
            let loader = LibraryRecallSource(includeFingerprints: true, cacheDirectory: cache)
            let library = await loader.load()
            let restored = await loader.restoredFromDisk, rebuilt = await loader.rebuiltNoteCount
            let loadMS = Int(Date().timeIntervalSince(t) * 1000)
            XCTAssertTrue(restored); XCTAssertEqual(rebuilt, 0)
            t = Date()
            let data = try await SecretaryPacketFiles.prepare(document: documentURL, cli: URL(fileURLWithPath: "/unused-cli"),
                                                              sourceKB: 64, library: library, marks: marks)
            let prepareMS = Int(Date().timeIntervalSince(t) * 1000)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let timings = (result["timings_ms"] as? [String: Double] ?? [:]).mapValues { Int($0) }
            print("BENCH run \(run): library_load \(loadMS) ms, prepare \(prepareMS) ms, total \(loadMS + prepareMS) ms, sources \(result["source_count"] ?? 0), stages \(timings.sorted { $0.key < $1.key })")
        }
    }
}
