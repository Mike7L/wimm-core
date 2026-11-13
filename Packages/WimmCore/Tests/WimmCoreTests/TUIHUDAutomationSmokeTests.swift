import XCTest
import WimmInfrastructure

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

final class TUIHUDAutomationSmokeTests: XCTestCase {
    func testHUDRunsWithFixtureAudioAndRecordedGeminiLiveScenario() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-tui-hud-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioFixture = try makeFixtureWAV(frameCount: 2048)
        defer { try? FileManager.default.removeItem(at: audioFixture) }

        let scenarioURL = try makeScenarioFile([
            ["payload": ["setupComplete": [:]]],
            ["payload": ["inputTranscription": ["text": "hud automated transcript"]], "delayMs": 10]
        ])
        defer { try? FileManager.default.removeItem(at: scenarioURL) }

        let executableURL = try locateWimmTUIExecutable()
        let scriptURL = URL(fileURLWithPath: "/usr/bin/script")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("/usr/bin/script is unavailable")
        }

        let stdout = Pipe()
        let stdin = Pipe()
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = ["-q", "/dev/null", executableURL.path, "hud", "--engine", "gemini-live"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout

        var env = ProcessInfo.processInfo.environment
        env["WIMM_ROOT_DIR"] = root.path
        env["WIMM_AUDIO_SOURCE"] = "fixture"
        env["WIMM_AUDIO_FIXTURE"] = audioFixture.path
        env["WIMM_AUDIO_FIXTURE_DELAY_MS"] = "0"
        env["WIMM_GEMINI_LIVE_TRANSPORT"] = "recorded"
        env["WIMM_GEMINI_LIVE_SCENARIO"] = scenarioURL.path
        env["GEMINI_API_KEY"] = "test-key"
        process.environment = env

        let collector = OutputCollector(stdout.fileHandleForReading)
        try process.run()

        try await driveHUD(process: process, stdin: stdin.fileHandleForWriting, output: collector)
        let output = collector.text

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("WIMM HUD"), output)
        XCTAssertTrue(output.contains("Recording saved as"), output)
        XCTAssertTrue(output.contains("hud automated transcript") || output.contains("Review transcript:"), output)

        let storage = FileSystemAdapter(rootDirectory: root)
        let notes = try await storage.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "hud automated transcript")
    }


    func testHUDRunsWithRecordedHybridGeminiScenario() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-tui-hud-hybrid-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioFixture = try makeFixtureWAV(frameCount: 2048)
        defer { try? FileManager.default.removeItem(at: audioFixture) }

        let streamingScenarioURL = try makeJSONFile([
            "partials": [["text": "native partial", "delayMs": 10]],
            "finalText": "native partial"
        ], prefix: "streaming-hybrid-scenario")
        defer { try? FileManager.default.removeItem(at: streamingScenarioURL) }

        let batchScenarioURL = try makeJSONFile([
            "text": "hybrid final transcript"
        ], prefix: "batch-hybrid-scenario")
        defer { try? FileManager.default.removeItem(at: batchScenarioURL) }

        let executableURL = try locateWimmTUIExecutable()
        let scriptURL = URL(fileURLWithPath: "/usr/bin/script")
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("/usr/bin/script is unavailable")
        }

        let stdout = Pipe()
        let stdin = Pipe()
        let process = Process()
        process.executableURL = scriptURL
        process.arguments = ["-q", "/dev/null", executableURL.path, "hud", "--engine", "gemini"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout

        var env = ProcessInfo.processInfo.environment
        env["WIMM_ROOT_DIR"] = root.path
        env["WIMM_AUDIO_SOURCE"] = "fixture"
        env["WIMM_AUDIO_FIXTURE"] = audioFixture.path
        env["WIMM_AUDIO_FIXTURE_DELAY_MS"] = "0"
        env["WIMM_STREAMING_TRANSCRIBER"] = "recorded"
        env["WIMM_STREAMING_TRANSCRIBE_SCENARIO"] = streamingScenarioURL.path
        env["WIMM_GEMINI_TRANSCRIBE_SCENARIO"] = batchScenarioURL.path
        env["GEMINI_API_KEY"] = "test-key"
        process.environment = env

        let collector = OutputCollector(stdout.fileHandleForReading)
        try process.run()

        try await driveHUD(process: process, stdin: stdin.fileHandleForWriting, output: collector)
        let output = collector.text

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("Recording saved as"), output)
        XCTAssertTrue(output.contains("hybrid final transcript") || output.contains("Review transcript:"), output)

        let storage = FileSystemAdapter(rootDirectory: root)
        let notes = try await storage.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "hybrid final transcript")
    }

    /// Plays the a → x → x → q key sequence, each key only once the HUD has
    /// printed the line the previous key produces. Fixed sleeps raced the
    /// subprocess when the full suite kept the machine busy.
    private func driveHUD(process: Process, stdin: FileHandle, output: OutputCollector) async throws {
        let steps: [(marker: String, key: String)] = [
            ("WIMM HUD", "a"),
            ("Auto-process after record:", "x"),
            ("Recording started.", "x"),
            ("Recording saved as", "q")
        ]
        for step in steps {
            guard await output.waitFor(step.marker, timeout: 30) else {
                XCTFail("Timed out waiting for \"\(step.marker)\"")
                break
            }
            stdin.write(Data(step.key.utf8))
        }
        // Always end the session, even after a timeout, so the subprocess exits.
        stdin.write(Data("q".utf8))
        try? stdin.close()

        // Poll instead of `waitUntilExit()`: called from a cooperative-pool
        // thread it can block forever after the child has already exited.
        if !(await poll(timeout: 30) { !process.isRunning }) {
            process.terminate()
            _ = await poll(timeout: 10) { !process.isRunning }
            XCTFail("wimm-tui did not exit")
        }
        _ = await output.waitForEOF(timeout: 10)
    }

    private func locateWimmTUIExecutable() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("Packages/WimmCore/.build/debug/wimm-tui"),
            cwd.appendingPathComponent("Packages/WimmCore/.build/arm64-apple-macosx/debug/wimm-tui"),
            cwd.appendingPathComponent(".build/debug/wimm-tui"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/wimm-tui")
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        throw XCTSkip("wimm-tui executable not found")
    }

    private func makeFixtureWAV(frameCount: AVAudioFrameCount) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-audio-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frameCount) {
            samples[index] = Float(index % 16) / 16.0
        }

        try file.write(from: buffer)
        return url
    }

    private func makeScenarioFile(_ payload: [[String: Any]]) throws -> URL {
        try makeJSONFile(payload, prefix: "gemini-live-hud-scenario")
    }

    private func makeJSONFile(_ payload: Any, prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Accumulates a pipe's output as it arrives so the driver can wait on markers.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var reachedEOF = false

    init(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.lock.lock()
            if chunk.isEmpty {
                self.reachedEOF = true
                handle.readabilityHandler = nil
            } else {
                self.data.append(chunk)
            }
            self.lock.unlock()
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    private var isAtEOF: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEOF
    }

    func waitFor(_ marker: String, timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.text.contains(marker) }
    }

    func waitForEOF(timeout: TimeInterval) async -> Bool {
        await poll(timeout: timeout) { self.isAtEOF }
    }

}

private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}

#else

final class TUIHUDAutomationSmokeTests: XCTestCase {
    func testPlatformPlaceholder() {
        XCTAssertTrue(true)
    }
}

#endif
