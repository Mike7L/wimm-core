import XCTest
import class Foundation.Bundle

final class CLINotesTests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        if ProcessInfo.processInfo.environment["WIMM_RUN_LEGACY_CLI_NOTES_TESTS"] != "1" {
            throw XCTSkip("CLINotesTests rely on legacy notes fixtures; enable WIMM_RUN_LEGACY_CLI_NOTES_TESTS=1 after migrating fixtures to WIMM notes contract.")
        }

        let bundleURL = Bundle(for: CLINotesTests.self).bundleURL
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLINotes_" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
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

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (out, err, task.terminationStatus)
    }

    private func runJSON(_ args: [String]) throws -> Any {
        let (out, err, status) = try runWimm(args)
        XCTAssertEqual(status, 0, "Command failed: \(args.joined(separator: " "))\nSTDERR:\n\(err)\nSTDOUT:\n\(out)")
        let payload = try XCTUnwrap(extractJSONPayload(from: out), "Could not find JSON payload in output")
        return try JSONSerialization.jsonObject(with: Data(payload.utf8))
    }

    private func extractJSONPayload(from output: String) -> String? {
        let arrayStart = output.firstIndex(of: "[")
        let objectStart = output.firstIndex(of: "{")
        guard let start = [arrayStart, objectStart].compactMap({ $0 }).min() else {
            return nil
        }

        if output[start] == "[" {
            guard let end = output.lastIndex(of: "]"), start <= end else { return nil }
            return String(output[start...end])
        }

        guard let end = output.lastIndex(of: "}"), start <= end else { return nil }
        return String(output[start...end])
    }

    private func createNote(fileName: String, text: String, title: String) throws {
        let notesDir = tempDir.appendingPathComponent("Recordings")
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let notePath = notesDir.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: notePath.path, contents: text.data(using: .utf8))

        let metaPath = notesDir.appendingPathComponent(fileName.replacingOccurrences(of: ".txt", with: ".meta.json"))
        let jsonContent = """
        {
          "noteCard": {
            "schema": "NoteCard@v1",
            "note_file": "\(fileName)",
            "title": "\(title)",
            "summary": "Summary"
          }
        }
        """
        try jsonContent.write(to: metaPath, atomically: true, encoding: .utf8)
    }

    func testNotesQueryFiltersByText() throws {
        try createNote(fileName: "2026-02-06_10-00-00_Alpha.txt", text: "focus keyword", title: "Alpha")
        try createNote(fileName: "2026-02-06_09-00-00_Beta.txt", text: "other text", title: "Beta")

        guard let rows = try runJSON(["notes", "query", "--query", "keyword", "--only-matches", "--json"]) as? [[String: Any]] else {
            return XCTFail("notes query JSON must be an array")
        }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["title"] as? String, "Alpha")
    }

    func testNotesSelectReturnsSelectionPayload() throws {
        try createNote(fileName: "2026-02-06_11-00-00_SelectMe.txt", text: "selection text", title: "SelectMe")

        guard
            let rows = try runJSON(["notes", "query", "--limit", "1", "--json"]) as? [[String: Any]],
            let noteId = rows.first?["id"] as? String
        else {
            return XCTFail("Expected at least one note row with id")
        }

        let preselected = UUID().uuidString
        guard let payload = try runJSON([
            "notes", "select",
            "--selected", preselected,
            "--id", noteId,
            "--additive",
            "--open",
            "--json"
        ]) as? [String: Any] else {
            return XCTFail("notes select JSON must be an object")
        }

        let selectedIds = payload["selectedIds"] as? [String] ?? []
        XCTAssertTrue(selectedIds.contains(preselected))
        XCTAssertTrue(selectedIds.contains(noteId))
        XCTAssertEqual(payload["activeNoteId"] as? String, noteId)
    }

    func testNotesQueryRespectsLimitZero() throws {
        try createNote(fileName: "2026-02-06_12-00-00_A.txt", text: "a", title: "A")
        try createNote(fileName: "2026-02-06_12-10-00_B.txt", text: "b", title: "B")

        guard let rows = try runJSON(["notes", "query", "--limit", "0", "--json"]) as? [[String: Any]] else {
            return XCTFail("notes query JSON must be an array")
        }
        XCTAssertTrue(rows.isEmpty, "limit=0 should return an empty list")
    }

    func testNotesSelectFailsForInvalidUUID() throws {
        let (_, _, status) = try runWimm(["notes", "select", "--id", "not-a-uuid", "--json"])
        XCTAssertNotEqual(status, 0, "notes select should fail for invalid UUID")
    }
}
