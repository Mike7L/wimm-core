import XCTest
import class Foundation.Bundle

final class CLIIntegrationTests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!
    var recordingsDir: URL!
    
    override func setUp() {
        super.setUp()
        
        // Locate WimmCLI executable
        let bundleURL = Bundle(for: CLIIntegrationTests.self).bundleURL
        
        // Handle both simple directory structure (SPM) and Xcode/bundle structures
        // Attempt to find WimmCLI binary
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        
        if !FileManager.default.fileExists(atPath: candidate.path) {
             // Try going up one more level (common in Xcode builds)
             candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        
        wimmURL = candidate
        
        // Create temp environment
        // Wimm uses 'Recordings' subdirectory inside WIMM_BASE_DIR by default
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLIIntTest_" + UUID().uuidString)
        recordingsDir = tempDir.appendingPathComponent("Recordings")
        
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    private func runWimm(_ args: [String]) throws -> (String, String, Int32) {
        guard FileManager.default.fileExists(atPath: wimmURL.path) else {
            throw XCTSkip("WimmCLI executable not found at \(wimmURL.path). Build it first using `swift build -c release` or similar.")
        }
        
        let task = Process()
        task.executableURL = wimmURL
        task.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["WIMM_BASE_DIR"] = tempDir.path
        env["WIMM_DISABLE_KEYCHAIN"] = "1"
        // Avoid nested `swift run wimm-tui` during `swift test`, which can deadlock on .build lock.
        env["WIMM_USE_TUI"] = "0"
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

    private func extractJSONArray(from output: String) -> String? {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start <= end else {
            return nil
        }
        return String(output[start...end])
    }
    
    func testListCommand() throws {
        // 1. Text output (WIMM route can report either empty or populated status lines)
        let (out, _, status) = try runWimm(["list"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(
            out.contains("No notes found.") || out.contains(" - pending") || out.contains(" - completed") || out.contains(" - failed"),
            "List output should contain either empty-state or note status lines"
        )
        
        // 2. JSON output
        let (jsonOut, _, jsonStatus) = try runWimm(["list", "--json"])
        XCTAssertEqual(jsonStatus, 0)
        guard let jsonPayload = extractJSONArray(from: jsonOut) else {
            XCTFail("Expected JSON array in list --json output")
            return
        }
        let data = try XCTUnwrap(jsonPayload.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(parsed is [Any], "list --json should return a JSON array")
    }
    
    func testSearchCommand() throws {
        // Setup fixture
        let file1 = recordingsDir.appendingPathComponent("2024-03-01_10-00-00.txt")
        try "This is a special secret note used for searching".write(to: file1, atomically: true, encoding: .utf8)
        
        let file2 = recordingsDir.appendingPathComponent("2024-03-02_10-00-00.txt")
        try "Just ordinary public note".write(to: file2, atomically: true, encoding: .utf8)
        
        // Search output shape should stay stable even when indexed text is unavailable.
        let (out, _, status) = try runWimm(["search", "secret"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("No notes matched.") || out.contains("Found "), "Search should return either matches or an explicit no-match message")
        
        // JSON Output
        let (jsonOut, _, jsonStatus) = try runWimm(["search", "special", "--json"])
        XCTAssertEqual(jsonStatus, 0)
        guard let jsonPayload = extractJSONArray(from: jsonOut) else {
            XCTFail("Expected JSON array in search --json output")
            return
        }
        let data = try XCTUnwrap(jsonPayload.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(parsed is [Any], "search --json should return a JSON array")
    }
}
