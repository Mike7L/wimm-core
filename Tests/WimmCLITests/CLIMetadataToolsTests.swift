import XCTest
import class Foundation.Bundle

final class CLIMetadataToolsTests: XCTestCase {
    var wimmURL: URL!
    var tempDir: URL!
    var recordingsDir: URL!

    override func setUp() {
        super.setUp()

        let bundleURL = Bundle(for: CLIMetadataToolsTests.self).bundleURL
        var candidate = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            candidate = bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        wimmURL = candidate

        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("WimmCLIMetaTools_" + UUID().uuidString)
        recordingsDir = tempDir.appendingPathComponent("Recordings")
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func runWimm(_ args: [String]) throws -> (String, String, Int32) {
        guard FileManager.default.fileExists(atPath: wimmURL.path) else {
            throw XCTSkip("WimmCLI executable not found at \(wimmURL.path)")
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

    func testMetaValidateFixCreatesMissingMetadata() throws {
        let note = recordingsDir.appendingPathComponent("meta_fix_note.txt")
        try "content".write(to: note, atomically: true, encoding: .utf8)
        let meta = recordingsDir.appendingPathComponent("meta_fix_note.meta.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: meta.path))

        let (out, _, status) = try runWimm(["meta", "validate", "--fix"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Meta validation complete."))
        XCTAssertTrue(FileManager.default.fileExists(atPath: meta.path))
    }

    func testAttachmentsAuditReportsMissingAttachmentAndOCR() throws {
        let note = recordingsDir.appendingPathComponent("attach_note.txt")
        try "content".write(to: note, atomically: true, encoding: .utf8)

        let missingAttachment = recordingsDir.appendingPathComponent("does_not_exist.png")
        let meta = recordingsDir.appendingPathComponent("attach_note.meta.json")
        let payload = """
        {
          "attachments": [
            {
              "id": "\(UUID().uuidString)",
              "url": "\(missingAttachment.absoluteString)",
              "type": "image"
            }
          ]
        }
        """
        try payload.write(to: meta, atomically: true, encoding: .utf8)

        let (out, _, status) = try runWimm(["attachments", "audit", "--json"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("\"missingFiles\" : 1"))
        XCTAssertTrue(out.contains("\"missingOCR\" : 1"))
    }

    func testTranscriptRebuildNormalizesLegacyTranscription() throws {
        let audio = recordingsDir.appendingPathComponent("legacy_audio.m4a")
        FileManager.default.createFile(atPath: audio.path, contents: Data())

        let meta = recordingsDir.appendingPathComponent("legacy_audio.meta.json")
        try """
        {
          "transcription": "legacy transcript text"
        }
        """.write(to: meta, atomically: true, encoding: .utf8)

        let (out, _, status) = try runWimm(["transcript", "rebuild", audio.path])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Rebuilt: 1"))

        let data = try Data(contentsOf: meta)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let transcription = json?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["transcript"] as? String, "legacy transcript text")
    }

    func testCleanOriginalsRefusesWithoutOptIn() throws {
        let original = recordingsDir.appendingPathComponent("large.m4a")
        try Data(repeating: 1, count: 1_200_000).write(to: original)
        try Data(repeating: 2, count: 10).write(to: recordingsDir.appendingPathComponent("large_micro.m4a"))

        let (out, _, status) = try runWimm(["clean", "originals", "--force"])
        XCTAssertNotEqual(status, 0)
        XCTAssertTrue(out.contains("Refusing"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testCleanOriginalsIgnoresMiniAndDeletesOnlyLargeOriginalsWithMicroWhenOptedIn() throws {
        let largeOriginal = recordingsDir.appendingPathComponent("large.m4a")
        let largeMicro = recordingsDir.appendingPathComponent("large_micro.m4a")
        let miniOnlyOriginal = recordingsDir.appendingPathComponent("mini_only.m4a")
        let noCompanionOriginal = recordingsDir.appendingPathComponent("without_companion.m4a")
        let smallOriginal = recordingsDir.appendingPathComponent("small.m4a")
        let smallMicro = recordingsDir.appendingPathComponent("small_micro.m4a")

        try Data(repeating: 1, count: 1_200_000).write(to: largeOriginal)
        try Data(repeating: 2, count: 10).write(to: largeMicro)
        try Data(repeating: 3, count: 1_300_000).write(to: miniOnlyOriginal)
        try Data(repeating: 3, count: 10).write(to: recordingsDir.appendingPathComponent("mini_only_mini.m4a"))
        try Data(repeating: 3, count: 1_300_000).write(to: noCompanionOriginal)
        try Data(repeating: 4, count: 100).write(to: smallOriginal)
        try Data(repeating: 5, count: 10).write(to: smallMicro)

        let (dryRunOut, _, dryRunStatus) = try runWimm(["clean", "originals", "--accept-micro-as-only-copy"])
        XCTAssertEqual(dryRunStatus, 0)
        XCTAssertTrue(dryRunOut.contains("large.m4a"))
        XCTAssertFalse(dryRunOut.contains("mini_only.m4a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: largeOriginal.path))

        let (out, _, status) = try runWimm(["clean", "originals", "--accept-micro-as-only-copy", "--force"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Deleted 1 files"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: largeOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: largeMicro.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: miniOnlyOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: noCompanionOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: smallOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: smallMicro.path))
    }

    func testCleanDerivedMiniKeepsOrphansAndListsThem() throws {
        let withOriginal = recordingsDir.appendingPathComponent("rec_a_mini.m4a")
        try Data(repeating: 1, count: 100).write(to: recordingsDir.appendingPathComponent("rec_a.m4a"))
        try Data(repeating: 2, count: 10).write(to: withOriginal)
        // An orphan: only a sidecar, a .txt and a _micro survive next to it.
        let orphan = recordingsDir.appendingPathComponent("rec_b_mini.m4a")
        try Data(repeating: 3, count: 10).write(to: orphan)
        try "{}".write(to: recordingsDir.appendingPathComponent("rec_b.meta.json"), atomically: true, encoding: .utf8)
        try "text".write(to: recordingsDir.appendingPathComponent("rec_b.txt"), atomically: true, encoding: .utf8)
        try Data(repeating: 4, count: 10).write(to: recordingsDir.appendingPathComponent("rec_b_micro.m4a"))
        for index in 0..<25 {
            try Data(repeating: 5, count: 10).write(to: recordingsDir.appendingPathComponent("lone_\(index)_mini.m4a"))
        }

        let (dryRun, _, dryStatus) = try runWimm(["clean", "derived", "--mini"])
        XCTAssertEqual(dryStatus, 0)
        XCTAssertTrue(dryRun.contains("Orphan, kept"), dryRun)
        XCTAssertTrue(dryRun.contains("and 6 more (use --list to see all)"), dryRun)

        let (listed, _, _) = try runWimm(["clean", "derived", "--mini", "--list"])
        XCTAssertTrue(listed.contains("rec_b_mini.m4a"), listed)
        XCTAssertTrue(listed.contains("lone_24_mini.m4a"), listed)
        XCTAssertFalse(listed.contains("more (use --list"), listed)

        let (out, _, status) = try runWimm(["clean", "derived", "--mini", "--force"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(out.contains("Deleted 1 derived audio file(s); kept 26 orphan(s)."), out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: withOriginal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordingsDir.appendingPathComponent("lone_0_mini.m4a").path))
    }

}
