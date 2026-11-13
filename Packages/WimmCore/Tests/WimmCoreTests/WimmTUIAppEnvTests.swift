import Foundation
import XCTest
@testable import WimmTUI

final class WimmTUIAppEnvTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wimm-env-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        unsetenv("WIMM_TEST_ENV")
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testParseEnvironmentAssignmentsSupportsCommentsExportAndQuotes() {
        let parsed = WimmTUIRuntime.parseEnvironmentAssignments(
            """
            # comment
            GEMINI_API_KEY=abc123
            export OPENROUTER_API_KEY="quoted value"
            EMPTY=
            INVALID LINE
            SINGLE='x y z'
            """
        )

        XCTAssertEqual(parsed.map(\.0), ["GEMINI_API_KEY", "OPENROUTER_API_KEY", "EMPTY", "SINGLE"])
        XCTAssertEqual(parsed[0].1, "abc123")
        XCTAssertEqual(parsed[1].1, "quoted value")
        XCTAssertEqual(parsed[2].1, "")
        XCTAssertEqual(parsed[3].1, "x y z")
    }

    func testDiscoverEnvironmentFilesFindsNearestEnvPair() throws {
        let nested = tempDir
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        let env = tempDir.appendingPathComponent(".env")
        let envLocal = tempDir.appendingPathComponent(".env.local")
        try "".write(to: env, atomically: true, encoding: .utf8)
        try "".write(to: envLocal, atomically: true, encoding: .utf8)

        let found = WimmTUIRuntime.discoverEnvironmentFiles(startingAt: nested)
        XCTAssertEqual(found.map(\.lastPathComponent), [".env", ".env.local"])
    }

    func testLoadEnvironmentFileDoesNotOverrideExistingVariables() throws {
        let envFile = tempDir.appendingPathComponent(".env")
        try "WIMM_TEST_ENV=from_file\n".write(to: envFile, atomically: true, encoding: .utf8)
        setenv("WIMM_TEST_ENV", "from_process", 1)

        let loaded = try WimmTUIRuntime.loadEnvironmentFile(envFile, overrideExisting: false)

        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(ProcessInfo.processInfo.environment["WIMM_TEST_ENV"], "from_process")
    }

    func testLoadEnvironmentFileSetsMissingVariables() throws {
        let envFile = tempDir.appendingPathComponent(".env")
        try "WIMM_TEST_ENV=from_file\n".write(to: envFile, atomically: true, encoding: .utf8)

        let loaded = try WimmTUIRuntime.loadEnvironmentFile(envFile, overrideExisting: false)

        XCTAssertEqual(loaded, ["WIMM_TEST_ENV"])
        XCTAssertEqual(ProcessInfo.processInfo.environment["WIMM_TEST_ENV"], "from_file")
    }
}
