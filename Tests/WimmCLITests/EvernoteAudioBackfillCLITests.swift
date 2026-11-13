import XCTest
import class Foundation.Bundle

final class EvernoteAudioBackfillCLITests: XCTestCase {
    func testApplyPersistsTranscriptAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvernoteAudioBackfillCLITests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let attachmentDirectory = root
            .appendingPathComponent("Attachments/Evernote/note-id", isDirectory: true)
        try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: attachmentDirectory,
            withIntermediateDirectories: true
        )

        let noteURL = recordings.appendingPathComponent("Wimm_2020-01-01_00-00-00_test.txt")
        try "Imported note".write(to: noteURL, atomically: true, encoding: .utf8)
        let attachmentURL = attachmentDirectory.appendingPathComponent("recording.m4a")
        try Data("audio fixture".utf8).write(to: attachmentURL)
        let attachmentID = UUID()
        let metadata: [String: Any] = [
            "importSource": "Evernote",
            "attachments": [[
                "id": attachmentID.uuidString,
                "url": attachmentURL.absoluteString,
                "type": "audio",
            ]],
        ]
        let metadataURL = recordings.appendingPathComponent(
            noteURL.deletingPathExtension().lastPathComponent + ".meta.json"
        )
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
            .write(to: metadataURL)

        let first = try runCLI(
            ["attachments", "transcribe-evernote", "--apply"],
            storageRoot: root
        )
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertTrue(first.stdout.contains("succeeded=1 failed=0"), first.stdout)

        let savedData = try Data(contentsOf: metadataURL)
        let saved = try XCTUnwrap(
            JSONSerialization.jsonObject(with: savedData) as? [String: Any]
        )
        let attachments = try XCTUnwrap(saved["attachments"] as? [[String: Any]])
        XCTAssertEqual(
            attachments.first?["extractedText"] as? String,
            "This is a mocked transcription for testing purposes."
        )

        let second = try runCLI(
            ["attachments", "transcribe-evernote"],
            storageRoot: root
        )
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertTrue(second.stdout.contains("Already transcribed: 1"), second.stdout)
        XCTAssertTrue(second.stdout.contains("Eligible: 0"), second.stdout)

        let analysis = try runCLI(
            ["attachments", "analyze-evernote-audio", "--apply"],
            storageRoot: root
        )
        XCTAssertEqual(analysis.status, 0, analysis.stderr)
        XCTAssertTrue(
            analysis.stdout.contains("Analysis backfill complete: succeeded=1 failed=0"),
            analysis.stdout
        )

        let analyzedData = try Data(contentsOf: metadataURL)
        let analyzed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: analyzedData) as? [String: Any]
        )
        XCTAssertEqual(
            (analyzed["noteCard"] as? [String: Any])?["title"] as? String,
            "Mocked Note Title"
        )
        let marker = try XCTUnwrap(
            (analyzed["analysisBackfills"] as? [String: Any])?["evernoteAudio"]
                as? [String: Any]
        )
        XCTAssertFalse((marker["transcriptHash"] as? String ?? "").isEmpty)

        let repeatedAnalysis = try runCLI(
            ["attachments", "analyze-evernote-audio"],
            storageRoot: root
        )
        XCTAssertEqual(repeatedAnalysis.status, 0, repeatedAnalysis.stderr)
        XCTAssertTrue(
            repeatedAnalysis.stdout.contains("Already analyzed for current transcripts: 1"),
            repeatedAnalysis.stdout
        )
        XCTAssertTrue(repeatedAnalysis.stdout.contains("Eligible: 0"), repeatedAnalysis.stdout)
    }

    private func runCLI(
        _ arguments: [String],
        storageRoot: URL
    ) throws -> (stdout: String, stderr: String, status: Int32) {
        let bundleURL = Bundle(for: Self.self).bundleURL
        var executable = bundleURL.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: executable.path) {
            executable = bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("WimmCLI")
        }
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("WimmCLI executable not found at \(executable.path)")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["WIMM_BASE_DIR"] = storageRoot.path
        environment["WIMM_TEST_MODE"] = "1"
        environment["WIMM_DISABLE_KEYCHAIN"] = "1"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        return (
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }
}
