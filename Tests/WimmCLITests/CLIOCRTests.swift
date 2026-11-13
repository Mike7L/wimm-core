import XCTest
import WimmDomain

import class Foundation.Bundle

final class CLIOCRTests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!
    var recordingsDir: URL!

    override func setUp() {
        super.setUp()

        let bundleURL = Bundle(for: CLIOCRTests.self).bundleURL
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WimmCLIOCR_" + UUID().uuidString)
        recordingsDir = tempDir.appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(
            at: recordingsDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
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

        let out =
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err =
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, task.terminationStatus)
    }

    func testOCRHelp() throws {
        let (out, _, status) = try runWimm(["ocr", "--help"])
        XCTAssertEqual(status, 0, "OCR help should succeed")
        XCTAssertTrue(
            out.contains("Extract text and scene descriptions from images and PDF"), "Help should describe OCR command")
        XCTAssertTrue(out.contains("--max-pages"), "Help should mention max-pages option")
        XCTAssertTrue(out.contains("--json"), "Help should mention json flag")
    }

    func testOCRTextFile() throws {
        // Create a text file and try to OCR it - should fail with unsupported type
        let textFile = recordingsDir.appendingPathComponent("test.txt")
        try "Hello world".write(to: textFile, atomically: true, encoding: .utf8)

        let (_, err, status) = try runWimm(["ocr", textFile.path])
        XCTAssertNotEqual(status, 0, "OCR on txt file should fail")
        XCTAssertTrue(err.contains("Unsupported file type"), "Should report unsupported type")
    }

    func testOCRMissingFile() throws {
        let (_, err, status) = try runWimm(["ocr", "/nonexistent/file.pdf"])
        XCTAssertNotEqual(status, 0, "OCR on missing file should fail")
        XCTAssertTrue(err.contains("File not found"), "Should report file not found")
    }

    func testRecentOCRFailuresReturnNonzeroWithoutChangingSidecar() throws {
        let image = recordingsDir.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: image)
        FileStore.upsertMetadata(for: image, updates: ["title": "Keep me", "transcription": ["transcript": "Previous text"]])
        let sidecar = FileStore.metadataURL(forRecordingURL: image)
        let original = try Data(contentsOf: sidecar)

        let (out, _, status) = try runWimm(["ocr", "--recent", "1", "--apply"])
        XCTAssertNotEqual(status, 0, out)
        XCTAssertTrue(out.contains("1 failed"), out)
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
    }

    func testOCRJSONOutput() throws {
        // Create a simple text-based PDF simulation isn't possible without actual PDF
        // So we test that --json flag works with error case
        let (out, _, _) = try runWimm(["ocr", "/nonexistent/file.pdf", "--json"])
        // Even on error, with --json the error should NOT be printed to stdout as regular text
        // (The error goes through the normal error path)
        // This is a basic structure test
        XCTAssertFalse(out.contains("File:"), "JSON mode should not print 'File:' label")
    }
}
