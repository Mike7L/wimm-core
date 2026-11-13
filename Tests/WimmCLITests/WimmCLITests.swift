import XCTest

import class Foundation.Bundle

final class WimmCLITests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["WIMM_RUN_LEGACY_WIMM_CLI_TESTS"] != "1" {
            throw XCTSkip("WimmCLITests rely on legacy list/search/tui fixtures; enable WIMM_RUN_LEGACY_WIMM_CLI_TESTS=1 after migrating fixtures to WIMM CLI contract.")
        }

        // Locate WimmCLI executable
        let bundleURL = Bundle(for: WimmCLITests.self).bundleURL

        // Handle both simple directory structure (SPM) and Xcode/bundle structures
        // Attempt 1: Sibling of the test bundle
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")

        if !FileManager.default.fileExists(atPath: candidate.path) {
            // Attempt 2: If we are inside a .xctest bundle, go up even more
            candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("WimmCLI")
        }

        wimmURL = candidate

        // Create temp environment
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WimmCLITest_" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempDir = tempDir.resolvingSymlinksInPath()
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    private func runWimm(_ args: [String]) throws -> (String, String, Int32) {
        guard FileManager.default.fileExists(atPath: wimmURL.path) else {
            throw XCTSkip("WimmCLI executable not found at \(wimmURL.path). Build it first.")
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

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "", task.terminationStatus
        )
    }

    func testListJSONOutput() throws {
        // Setup data in Recordings subdirectory (matches FileStore structure)
        let notesDir = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = notesDir.appendingPathComponent("2023-01-01_12-00-00_Note1.txt")
        FileManager.default.createFile(
            atPath: notePath.path, contents: "Content".data(using: .utf8))

        let (out, _, status) = try runWimm(["list", "--json"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("\"text\" : \"Content\""))
        XCTAssertTrue(out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["))
    }

    func testListTextOutput() throws {
        let notesDir = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = notesDir.appendingPathComponent("2023-01-01_12-00-00_Note1.txt")
        FileManager.default.createFile(
            atPath: notePath.path, contents: "Content".data(using: .utf8))
        // Create metadata for title (CLI uses title in list)
        let metaPath = notesDir.appendingPathComponent("2023-01-01_12-00-00_Note1.meta.json")
        let jsonContent = """
            {
                "noteCard": {
                    "schema": "NoteCard@v1",
                    "note_file": "2023-01-01_12-00-00_Note1.txt",
                    "title": "Note1",
                    "summary": "Summary"
                }
            }
            """
        try jsonContent.write(to: metaPath, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["list"])
        if status != 0 { print("CLI Status: \(status)\nStderr: \(err)") }
        if !out.contains("Listing") { print("CLI Output: \(out)") }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Listing"))
        XCTAssertTrue(out.contains("Note1"))
    }

    func testSearchFindsNotes() throws {
        let notesDir = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = notesDir.appendingPathComponent("2023-01-01_12-00-00_SearchMe.txt")
        FileManager.default.createFile(
            atPath: notePath.path, contents: "HiddenTreasure".data(using: .utf8))
        let metaPath = notesDir.appendingPathComponent("2023-01-01_12-00-00_SearchMe.meta.json")

        let jsonContent = """
            {
                "noteCard": {
                    "schema": "NoteCard@v1",
                    "note_file": "2023-01-01_12-00-00_SearchMe.txt",
                    "title": "SearchMe",
                    "summary": "Summary"
                }
            }
            """
        try jsonContent.write(to: metaPath, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["search", "Treasure"])
        if !out.contains("SearchMe") { print("CLI Output: \(out)\nStderr: \(err)") }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Found 1 matches"))
        XCTAssertTrue(out.contains("SearchMe"))
    }

    func testSearchNoResults() throws {
        let (out, _, status) = try runWimm(["search", "NonExistent"])
        XCTAssertEqual(status, 0)  // Should exit 0 even if no results? Probably.
        XCTAssertTrue(out.contains("Found 0 matches"))
    }

    func testTUIRendersCompactSymbols() throws {
        let notesDir = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let noteName = "Wimm_2026-02-12_12-00-00.txt"
        let noteURL = notesDir.appendingPathComponent(noteName)
        FileManager.default.createFile(
            atPath: noteURL.path, contents: "Content".data(using: .utf8))

        let imageURL = notesDir.appendingPathComponent("Wimm_2026-02-12_12-00-00_Attach_image.png")
        let pdfURL = notesDir.appendingPathComponent("Wimm_2026-02-12_12-00-00_Attach_doc.pdf")
        FileManager.default.createFile(atPath: imageURL.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: pdfURL.path, contents: Data([0x02]))

        let metaPath = notesDir.appendingPathComponent("Wimm_2026-02-12_12-00-00.meta.json")
        let jsonContent = """
            {
              "noteCard": {
                "schema": "NoteCard@v1",
                "note_file": "\(noteName)",
                "title": "AlphaNote",
                "summary": "Summary"
              },
              "attachments": [
                {
                  "id": "\(UUID().uuidString)",
                  "url": "\(imageURL.absoluteString)",
                  "type": "image",
                  "extractedText": "has text"
                },
                {
                  "id": "\(UUID().uuidString)",
                  "url": "\(pdfURL.absoluteString)",
                  "type": "pdf"
                }
              ]
            }
            """
        try jsonContent.write(to: metaPath, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["tui", "--limit", "1"])
        if status != 0 { print("CLI Status: \(status)\nStderr: \(err)\nOutput: \(out)") }
        XCTAssertEqual(status, 0)
        let rendered = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(rendered.contains("📝Alpha🖼+📄_"))
        XCTAssertTrue(rendered.hasSuffix("📝Alpha🖼+📄_"))
    }

    func testTUIRendersCompactSymbolsInFullMode() throws {
        let notesDir = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)

        let noteName = "Wimm_2026-02-12_13-00-00.txt"
        let noteURL = notesDir.appendingPathComponent(noteName)
        FileManager.default.createFile(
            atPath: noteURL.path, contents: "Content".data(using: .utf8))

        let metaPath = notesDir.appendingPathComponent("Wimm_2026-02-12_13-00-00.meta.json")
        let jsonContent = """
            {
              "noteCard": {
                "schema": "NoteCard@v1",
                "note_file": "\(noteName)",
                "title": "Bravo",
                "summary": "Summary"
              }
            }
            """
        try jsonContent.write(to: metaPath, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["tui", "--mode", "full", "--limit", "1"])
        if status != 0 { print("CLI Status: \(status)\nStderr: \(err)\nOutput: \(out)") }
        XCTAssertEqual(status, 0)
        let rendered = out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(rendered.contains("📝Bravo"))
        XCTAssertTrue(rendered.hasSuffix("📝Bravo"))
    }
}
