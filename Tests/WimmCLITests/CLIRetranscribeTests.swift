import XCTest
import class Foundation.Bundle

/// `wimm-cli transcript retranscribe` over a temp library (`WIMM_BASE_DIR`).
/// `WIMM_TEST_MODE` swaps the provider for the deterministic adapter, which
/// still writes through `recordRunSuccess` — so the sidecar rules are real.
final class CLIRetranscribeTests: XCTestCase {
    private var wimmURL: URL!
    private var tempDir: URL!
    private var audio: URL!
    private var sidecar: URL!

    private static let mocked = "This is a mocked transcription for testing purposes."

    override func setUpWithError() throws {
        try super.setUpWithError()
        let bundleURL = Bundle(for: CLIRetranscribeTests.self).bundleURL
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLIRetranscribe_" + UUID().uuidString)
        let recordings = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        audio = recordings.appendingPathComponent("Wimm_2026-10-13_01-08-40_BD002026.m4a")
        sidecar = recordings.appendingPathComponent("Wimm_2026-10-13_01-08-40_BD002026.meta.json")
        try Data([0, 1, 2]).write(to: audio)
        let meta: [String: Any] = [
            "transcription": [
                "transcript": "Да. Да. Да.",
                "provider": "gemini", "model": "gemini-flash-lite-latest",
                "startedAt": "2026-10-13T01:10:00Z", "speechStatus": "speech",
            ],
        ]
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]).write(to: sidecar)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func runWimm(_ args: [String], privateMode: Bool = false) throws -> (String, Int32) {
        guard FileManager.default.fileExists(atPath: wimmURL.path) else {
            throw XCTSkip("WimmCLI executable not found at \(wimmURL.path)")
        }
        let task = Process()
        task.executableURL = wimmURL
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["WIMM_BASE_DIR"] = tempDir.path
        env["WIMM_DISABLE_KEYCHAIN"] = "1"
        env["WIMM_TEST_MODE"] = "1"
        env["WIMM_PRIVATE_MODE"] = privateMode ? "1" : "0"
        task.environment = env
        let stdout = Pipe()
        task.standardOutput = stdout
        task.standardError = FileHandle.nullDevice
        try task.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(data: out, encoding: .utf8) ?? "", task.terminationStatus)
    }

    private func transcription() throws -> [String: Any] {
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any]
        return try XCTUnwrap(meta?["transcription"] as? [String: Any])
    }

    func testDryRunResolvesFileNameAndWritesNothing() throws {
        let before = try Data(contentsOf: sidecar)
        let (out, status) = try runWimm(["transcript", "retranscribe", "Wimm_2026-10-13_01-08-40_BD002026",
                                         "--model", "gemini-test-model"])
        XCTAssertEqual(status, 0, out)
        XCTAssertTrue(out.contains("DRY-RUN"), out)
        XCTAssertTrue(out.contains("Wimm_2026-10-13_01-08-40_BD002026.m4a"), out)
        XCTAssertTrue(out.contains("current 3 words"), out)
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
    }

    func testApplyReplacesTranscriptAndKeepsTheOldOneAsPreviousRun() throws {
        let (out, status) = try runWimm(["transcript", "retranscribe", "Wimm_2026-10-13_01-08-40_BD002026.m4a",
                                         "--model", "gemini-test-model", "--no-analyze", "--apply"])
        XCTAssertEqual(status, 0, out)
        XCTAssertTrue(out.contains("speech: 3 → 8 words"), out)
        let transcription = try transcription()
        XCTAssertEqual(transcription["transcript"] as? String, Self.mocked)
        let previous = try XCTUnwrap(transcription["previousRuns"] as? [[String: Any]])
        XCTAssertEqual(previous.last?["transcript"] as? String, "Да. Да. Да.")
    }

    func testPrivateModeRefusesCloudModelBeforeAnyRun() throws {
        let before = try Data(contentsOf: sidecar)
        let (out, status) = try runWimm(["transcript", "retranscribe", "Wimm_2026-10-13_01-08-40_BD002026",
                                         "--model", "gemini-test-model", "--apply"], privateMode: true)
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(out.contains("would send the audio to the cloud"), out)
        XCTAssertEqual(try Data(contentsOf: sidecar), before)
    }

    func testUnknownNoteFails() throws {
        let (_, status) = try runWimm(["transcript", "retranscribe", "no-such-note", "--model", "gemini-test-model"])
        XCTAssertNotEqual(status, 0)
    }
}
