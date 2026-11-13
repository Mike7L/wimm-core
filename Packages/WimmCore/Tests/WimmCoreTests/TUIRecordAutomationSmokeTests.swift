import XCTest
import WimmInfrastructure

#if canImport(AVFoundation)
@preconcurrency import AVFoundation

final class TUIRecordAutomationSmokeTests: XCTestCase {
    func testRecordCommandRunsWithFixtureAudioAndRecordedGeminiLiveScenario() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-tui-record-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audioFixture = try makeFixtureWAV(frameCount: 2048)
        defer { try? FileManager.default.removeItem(at: audioFixture) }

        let scenarioURL = try makeScenarioFile([
            ["payload": ["setupComplete": [:]]],
            ["payload": ["inputTranscription": ["text": "automated transcript"]], "delayMs": 10]
        ])
        defer { try? FileManager.default.removeItem(at: scenarioURL) }

        let executableURL = try locateWimmTUIExecutable()
        let stdout = Pipe()
        let stdin = Pipe()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["record", "--engine", "gemini-live", "--auto-process", "off"]
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

        try process.run()

        Task.detached {
            try? await Task.sleep(nanoseconds: 250_000_000)
            stdin.fileHandleForWriting.write(Data("\n".utf8))
            try? stdin.fileHandleForWriting.close()
        }

        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("Saved note:"), output)
        XCTAssertTrue(output.contains("Final transcript: automated transcript"), output)

        let storage = FileSystemAdapter(rootDirectory: root)
        let notes = try await storage.loadAll()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "automated transcript")
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gemini-live-scenario-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
        return url
    }
}

#else

final class TUIRecordAutomationSmokeTests: XCTestCase {
    func testPlatformPlaceholder() {
        XCTAssertTrue(true)
    }
}

#endif
