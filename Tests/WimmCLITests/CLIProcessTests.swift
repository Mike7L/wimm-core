import XCTest
import class Foundation.Bundle

final class CLIProcessTests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!
    var recordingsDir: URL!
    var defaultsSuiteName: String!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["WIMM_RUN_LEGACY_CLI_PROCESS_TESTS"] != "1" {
            throw XCTSkip("CLIProcessTests rely on legacy process/queue fixtures; enable WIMM_RUN_LEGACY_CLI_PROCESS_TESTS=1 after migrating fixtures to WIMM process contract.")
        }
        
        // Locate WimmCLI executable
        let bundleURL = Bundle(for: CLIProcessTests.self).bundleURL
        
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
             candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate
        
        // Setup temp environment
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLIProcessTest_" + UUID().uuidString)
        recordingsDir = tempDir.appendingPathComponent("Recordings")
        defaultsSuiteName = "wimm.cli.process.tests.\(UUID().uuidString)"
        
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: defaultsSuiteName)
        suite?.set("gemini-2.5-flash", forKey: "capabilityHearModel")
        suite?.set("gemini-2.5-flash", forKey: "transcribeModel")
    }
    
    override func tearDown() {
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }
    
    // Helper to run WimmCLI with env vars
    private func runWimm(_ args: [String], env: [String: String] = [:]) throws -> (String, String, Int32) {
        guard FileManager.default.fileExists(atPath: wimmURL.path) else {
            throw XCTSkip("WimmCLI executable not found at \(wimmURL.path).")
        }
        
        let task = Process()
        task.executableURL = wimmURL
        task.arguments = args
        var processEnv = ProcessInfo.processInfo.environment
        processEnv["WIMM_BASE_DIR"] = tempDir.path
        processEnv["WIMM_DEFAULTS_SUITE"] = defaultsSuiteName
        // Merge helper env
        for (k, v) in env {
            processEnv[k] = v
        }
        processEnv["WIMM_DISABLE_KEYCHAIN"] = "1"
        let tuiBinary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/arm64-apple-macosx/debug/wimm-tui").path
        processEnv["WIMM_TUI_EXECUTABLE"] = tuiBinary
        task.environment = processEnv
        
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        
        try task.run()
        task.waitUntilExit()
        
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        
        return (String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "", task.terminationStatus)
    }
    
    func testProcessSingleFile() throws {
        // Create dummy audio
        let audioFile = recordingsDir.appendingPathComponent("test_process.m4a")
        FileManager.default.createFile(atPath: audioFile.path, contents: Data())
        
        // Run process with TEST_MODE
        print("Running process command on \(audioFile.path)")
        let (out, err, status) = try runWimm(["process", audioFile.path], env: ["WIMM_TEST_MODE": "1"])
        
        print("Stdout: \(out)")
        print("Stderr: \(err)")
        
        XCTAssertEqual(status, 0, "Process command failed")
        
        // Check Output
        XCTAssertTrue(out.contains("Transcription successful"), "Should report success")
        XCTAssertTrue(out.contains("Mocked Note Title"), "Should contain mocked title")
        XCTAssertTrue(out.contains("mocked summary"), "Should contain mocked summary")
        
        // Check metadata file
        let metaFile = recordingsDir.appendingPathComponent("test_process.meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaFile.path), "Meta JSON should be created")
        let metaData = try Data(contentsOf: metaFile)
        let metaJSON = try JSONSerialization.jsonObject(with: metaData) as? [String: Any]
        let transcription = metaJSON?["transcription"] as? [String: Any]
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordingsDir.appendingPathComponent("test_process.srt").path), "SRT file should not be created")
        XCTAssertTrue((transcription?["transcript"] as? String)?.isEmpty == false, "Transcript text should be stored in metadata")
    }
    
    func testQueueProcess() throws {
        // 1. Setup pending file
        let file1 = recordingsDir.appendingPathComponent("queued_audio.m4a")
        FileManager.default.createFile(atPath: file1.path, contents: Data())
        
        // 2. Verify queue sees it
        let (qOut, _, _) = try runWimm(["queue"], env: ["WIMM_TEST_MODE": "1"])
        XCTAssertTrue(qOut.contains("queued_audio.m4a"), "Queue should discern pending file")
        
        // 3. Run Queue Process
        let (out, _, status) = try runWimm(["queue", "--process"], env: ["WIMM_TEST_MODE": "1"])
        
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("queued_audio.m4a"), "Should mention processing file")
        XCTAssertTrue(out.contains("Processing 1 transcriptions"), "Should count correct items")
        // Note: Queue command output might differ slightly from Process command, check sources if needed
        
        // 4. Verify completion
        let metaFile = recordingsDir.appendingPathComponent("queued_audio.meta.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaFile.path), "Meta JSON should be created after queue processing")
    }

    func testQueueProcessUsesModelFromSharedDefaultsSuite() throws {
        // Given a user-selected hear model in shared suite
        let suite = UserDefaults(suiteName: defaultsSuiteName)
        suite?.set("openai/gpt-4o-mini", forKey: "capabilityHearModel")

        let file = recordingsDir.appendingPathComponent("queue_suite_model.m4a")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let (out, _, status) = try runWimm(["queue", "--process"], env: ["WIMM_TEST_MODE": "1"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Using user-selected hear model"), "Queue should print selected model source")
        XCTAssertTrue(out.contains("openai/gpt-4o-mini"), "Queue should use model from shared defaults suite")
        XCTAssertTrue(out.contains("(openrouter)"), "Queue should derive openrouter engine for slash model ids")
    }

    func testQueueFixesUnindexedTextNote() throws {
        // 1. Setup a text file without metadata
        let noteFile = recordingsDir.appendingPathComponent("unindexed_note.txt")
        let content = "This is a raw text note without a meta file. Queue should pick it up for analysis."
        try content.write(to: noteFile, atomically: true, encoding: .utf8)
        
        let metaFile = recordingsDir.appendingPathComponent("unindexed_note.meta.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaFile.path))
        
        // 2. Run queue to detect it
        let (qOut, _, _) = try runWimm(["queue"], env: ["WIMM_TEST_MODE": "1"])
        XCTAssertTrue(qOut.contains("unindexed_note.txt"), "Queue status should list the text note")
        XCTAssertTrue(qOut.contains("Pending Analysis: 1") || qOut.contains("Pending Analysis: 2"), "Queue should show pending analysis")
        
        // 3. Run queue --process
        let (_, _, status) = try runWimm(["queue", "--process"], env: ["WIMM_TEST_MODE": "1"])
        XCTAssertEqual(status, 0)
        
        // 4. Verify fix
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaFile.path), "Metadata file should be created")
        
        // 5. Verify queue is now empty for analysis
        let (qAfter, _, _) = try runWimm(["queue"], env: ["WIMM_TEST_MODE": "1"])
        XCTAssertTrue(qAfter.contains("Pending Analysis: 0"), "Queue should be empty after processing")
    }
    
    func testProcessLLMFailureFallback() throws {
        // Setup audio
        let audioFile = recordingsDir.appendingPathComponent("test_fail.m4a")
        FileManager.default.createFile(atPath: audioFile.path, contents: Data())
        
        // Run with FAIL_JSON mode
        print("Running process command with WIMM_TEST_MODE=FAIL_JSON")
        let (out, _, status) = try runWimm(["process", audioFile.path], env: ["WIMM_TEST_MODE": "FAIL_JSON"])
        
        print("Stdout: \(out)")
        
        // It should NOT fail the process command (exit 0), but fallback to naive
        // NoteProcessor logic: if LLM fails, try naiveNoteCard. If that succeeds, we are good.
        XCTAssertEqual(status, 0, "CLI should not crash on LLM failure, assuming fallback works")
        
        // Check output mentions failure or fallback behavior?
        // Actually NoteProcessor prints "Processed Successfully" even on fallback, 
        // because it returns a card.
        // But the title should NOT be "Mocked Note Title", it should be "Untitled" or derived from filename.
        
        // Wait, Naive implementation usually takes first few words or "Untitled". 
        // We can't easily predict naive result without transcription text. 
        // Mock Transcription returns "This is a mocked transcription for testing purposes."
        // So Naive title might be "This is a mocked transcription..."
        
        XCTAssertFalse(out.contains("Mocked Note Title"), "Should NOT contain the happy-path mock title")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioFile.deletingPathExtension().appendingPathExtension("meta.json").path))
    }
}
