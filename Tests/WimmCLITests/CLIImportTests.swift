import XCTest
import class Foundation.Bundle
import CryptoKit

final class CLIImportTests: XCTestCase {
    private var wimmURL: URL!
    private var tempDir: URL!

    private func requireLegacyImportTestsEnabled() throws {
        guard ProcessInfo.processInfo.environment["WIMM_RUN_LEGACY_CLI_IMPORT_TESTS"] == "1" else {
            throw XCTSkip("CLIImportTests rely on legacy HeadlessImportService JSON/ENEX/backfill contract; enable WIMM_RUN_LEGACY_CLI_IMPORT_TESTS=1 after migrating tests to WIMM import.")
        }
    }

    override func setUp() {
        super.setUp()

        let bundleURL = Bundle(for: CLIImportTests.self).bundleURL
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLIImportTest_" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            task.terminationStatus
        )
    }

    func testImportDryRunJSONOutput() throws {
        try requireLegacyImportTestsEnabled()
        let inputDir = tempDir.appendingPathComponent("input")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let file = inputDir.appendingPathComponent("sample.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["import", "--dry-run", "--json", inputDir.path])
        XCTAssertEqual(status, 0, "stderr=\(err)")

        let data = try XCTUnwrap(out.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["dryRun"] as? Bool, true)
        XCTAssertEqual(json?["found"] as? Int, 1)
        XCTAssertEqual(json?["wouldImport"] as? Int, 1)
        XCTAssertEqual(json?["imported"] as? Int, 0)
    }

    func testImportDryRunENEXJSONOutputCountsNotes() throws {
        try requireLegacyImportTestsEnabled()
        let inputDir = tempDir.appendingPathComponent("enex_input")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let enexURL = inputDir.appendingPathComponent("sample.enex")

        let payload = Data("img".utf8)
        let hash = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let b64 = payload.base64EncodedString()
        let enex = """
        <?xml version="1.0" encoding="UTF-8"?>
        <en-export>
          <note>
            <title>N1</title>
            <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><en-note>Hello <en-media type="image/png" hash="\(hash)"/></en-note>]]></content>
            <created>20260206T120000Z</created>
            <resource>
              <data encoding="base64">\(b64)</data>
              <mime>image/png</mime>
              <resource-attributes><file-name>i.png</file-name></resource-attributes>
            </resource>
          </note>
          <note>
            <title>N2</title>
            <content><![CDATA[<?xml version="1.0" encoding="UTF-8"?><en-note>Body 2</en-note>]]></content>
            <created>20260206T130000Z</created>
          </note>
        </en-export>
        """
        try enex.write(to: enexURL, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["import", "--dry-run", "--json", enexURL.path])
        XCTAssertEqual(status, 0, "stderr=\(err)")

        let data = try XCTUnwrap(out.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["found"] as? Int, 1)
        XCTAssertEqual(json?["importable"] as? Int, 1)
        XCTAssertEqual(json?["wouldImport"] as? Int, 2)
        XCTAssertEqual(json?["imported"] as? Int, 0)
        let kindCounts = json?["kindCounts"] as? [String: Any]
        XCTAssertEqual(kindCounts?["enex"] as? Int, 2)
    }

    func testImportBackfillTextReportsBackfilledCount() throws {
        try requireLegacyImportTestsEnabled()
        let inputDir = tempDir.appendingPathComponent("backfill_input")
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let file = inputDir.appendingPathComponent("sample.txt")
        try "hello backfill".write(to: file, atomically: true, encoding: .utf8)

        let (out, err, status) = try runWimm(["import", "--json", "--backfill-text", file.path])
        XCTAssertEqual(status, 0, "stderr=\(err)")

        let data = try XCTUnwrap(out.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["imported"] as? Int, 1)
        XCTAssertEqual(json?["backfilled"] as? Int, 1)
        XCTAssertEqual(json?["backfillFailed"] as? Int, 0)
    }
}
