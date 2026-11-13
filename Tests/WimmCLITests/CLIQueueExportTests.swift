import XCTest
import class Foundation.Bundle

final class CLIQueueExportTests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!
    var recordingsDir: URL!
    var defaultsSuiteName: String!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["WIMM_RUN_LEGACY_CLI_QUEUE_EXPORT_TESTS"] != "1" {
            throw XCTSkip("CLIQueueExportTests rely on legacy queue/export fixtures; enable WIMM_RUN_LEGACY_CLI_QUEUE_EXPORT_TESTS=1 after migrating fixtures to WIMM queue/export contract.")
        }
        
        // Locate WimmCLI executable
        let bundleURL = Bundle(for: CLIQueueExportTests.self).bundleURL
        
        // Standard SPM location vs Xcode location search
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
             candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate
        
        // Setup temp environment
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLIQueueTest_" + UUID().uuidString)
        recordingsDir = tempDir.appendingPathComponent("Recordings")
        defaultsSuiteName = "wimm.cli.queue.tests.\(UUID().uuidString)"
        
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
    
    private func runWimm(_ args: [String]) throws -> (String, String, Int32) {
        guard FileManager.default.fileExists(atPath: wimmURL.path) else {
            throw XCTSkip("WimmCLI executable not found at \(wimmURL.path).")
        }
        
        let task = Process()
        task.executableURL = wimmURL
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["WIMM_BASE_DIR"] = tempDir.path
        env["WIMM_DEFAULTS_SUITE"] = defaultsSuiteName
        env["WIMM_DISABLE_KEYCHAIN"] = "1"
        let tuiBinary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/arm64-apple-macosx/debug/wimm-tui").path
        env["WIMM_TUI_EXECUTABLE"] = tuiBinary
        task.environment = env
        
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
    
    // MARK: - Queue Tests
    
    func testQueueDetection() throws {
        // Create a dummy audio file that needs processing
        let audioFile = recordingsDir.appendingPathComponent("test_queue_audio.m4a")
        FileManager.default.createFile(atPath: audioFile.path, contents: Data())
        
        // Run 'queue' command (default view mode)
        let (out, _, status) = try runWimm(["queue"])
        XCTAssertEqual(status, 0)
        
        // It should report pending transcription
        XCTAssertTrue(out.contains("test_queue_audio.m4a"), "Queue output should list the pending audio file")
        XCTAssertTrue(out.contains("Pending Transcription") || out.contains("Waiting"), "Should indicate pending status")
    }
    
    // MARK: - Export Tests
    
    func testExportSingleFile() throws {
        // Create a dummy note for a specific month
        // Use Wimm_ prefix to ensure CLI extracts date correctly regardless of creation time
        let filename = "Wimm_2023-10-15_12-00-00.txt"
        let noteFile = recordingsDir.appendingPathComponent(filename)
        let content = "This is a test note for export functionality."
        try content.write(to: noteFile, atomically: true, encoding: .utf8)
        
        // Run export for that month including unprocessed files
        let outputFile = tempDir.appendingPathComponent("export_test.md")
        let (out, err, status) = try runWimm([
            "export",
            "--month", "2023-10",
            "--single-file",
            "--include-unprocessed",
            "--output", outputFile.path
        ])
        
        XCTAssertEqual(status, 0, "Export command failed. Stderr: \(err), Stdout: \(out)")
        
        // Check if file created
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path), "Output file should exist at \(outputFile.path)")
        
        // Check content
        let exportedContent = try String(contentsOf: outputFile)
        XCTAssertTrue(exportedContent.contains(content), "Exported file should contain note content")
        XCTAssertTrue(exportedContent.contains("2023-10-15"), "Exported file should contain date")
    }

    func testExportFolder() throws {
        // 2 notes with Wimm_ prefix to match date logic
        let f1 = recordingsDir.appendingPathComponent("Wimm_2023-10-01_10-00-00.txt")
        try "Note A: Detailed content for testing export functionality".write(to: f1, atomically: true, encoding: .utf8)
        
        let f2 = recordingsDir.appendingPathComponent("Wimm_2023-10-02_10-00-00.txt")
        try "Note B: Detailed content for testing export functionality".write(to: f2, atomically: true, encoding: .utf8)
        
        let outputDir = tempDir.appendingPathComponent("ExportDir")
        
        let (out, err, status) = try runWimm([
            "export",
            "--month", "2023-10",
            "--include-unprocessed",
            "--output", outputDir.path
        ])
        
        XCTAssertEqual(status, 0, "Dir export failed: \(err), Stdout: \(out)")
        
        // Export command creates a subfolder named Wimm_Export_... .wimmbundle
        // We need to find it
        let contents = try FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)
        let bundleURL = contents.first { $0.pathExtension == "wimmbundle" }
        
        XCTAssertNotNil(bundleURL, "Should have created a .wimmbundle folder")
        guard let bundle = bundleURL else { return }
        
        // Check for chronicle.md inside the bundle
        let chronicle = bundle.appendingPathComponent("chronicle.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chronicle.path))
        
        let text = try String(contentsOf: chronicle)
        XCTAssertTrue(text.contains("Note A"))
        XCTAssertTrue(text.contains("Note B"))
    }
}
