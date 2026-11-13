import XCTest
import WimmDomain
import WimmInfrastructure

final class CLIDepersonalizeTests: XCTestCase {
    private var base: URL!
    private var binary: URL!

    override func setUpWithError() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        binary = products.appendingPathComponent("WimmCLI")
        if !FileManager.default.fileExists(atPath: binary.path) {
            binary = products.deletingLastPathComponent().appendingPathComponent("WimmCLI")
        }
        // Missing binaries are a test failure: otherwise a stale build can hide
        // a command that was never registered in WimmCLI.
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cli-depersonalize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try FileManager.default.removeItem(at: base) }
    }

    func testStdinUsesVocabularyAndPrintsOnlyMaskedTextToStdout() async throws {
        let store = PersonalGlossaryStore(directory: base.appendingPathComponent("Glossary"))
        var document = try await store.read()
        document.terms = [.init(canonical: "Маша", context: "Synthetic person", kind: .person, sensitive: true)]
        _ = try await store.save(document)
        let before = try files()
        let result = try run(["--text-file", "-"], stdin: "Маша пишет test@example.org")
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("⟦P"), result.out)
        XCTAssertFalse(result.out.contains("Маша"))
        XCTAssertFalse(result.out.contains("example.org"))
        XCTAssertTrue(result.err.contains("possibly not hidden:"))
        XCTAssertEqual(try files(), before)
    }

    func testNotePathAndFilenameIncludeLegacyAttachmentsWithoutWriting() throws {
        let note = base.appendingPathComponent("Recordings/Wimm_2026-10-25_10-00-00_synthetic.txt")
        try "Contact body@example.org".write(to: note, atomically: true, encoding: .utf8)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) {
            $0["attachments"] = [["id": UUID().uuidString, "url": note.absoluteString,
                                   "type": "pdf", "ocrText": "Attachment attachment@example.org"]]
            return true
        }
        let before = try files()
        for reference in [note.path, note.lastPathComponent] {
            let result = try run([reference, "--json"])
            XCTAssertEqual(result.status, 0, result.err)
            let report = try object(result.out)
            XCTAssertEqual(report["wouldSend"] as? Bool, true)
            XCTAssertEqual(report["maskedEntities"] as? Int, 2)
            XCTAssertTrue((report["text"] as? String)?.contains("[ATTACHMENT_1_OCR") == true)
            XCTAssertFalse(result.out.contains("example.org"))
            XCTAssertNil(report["legend"])
            XCTAssertEqual(try files(), before)
        }
    }

    func testRawTextFileReportsUnhiddenNamesWithoutLearningThem() throws {
        let text = base.appendingPathComponent("input.md")
        try "Сегодня встретил Оксану, ответить на test@example.org".write(to: text, atomically: true, encoding: .utf8)
        let before = try files()
        let result = try run(["--text-file", text.path, "--json"], privateMode: false)
        XCTAssertEqual(result.status, 0, result.err)
        let report = try object(result.out)
        XCTAssertEqual(report["dictionaryTerms"] as? Int, 0)
        let suspects = try XCTUnwrap(report["suspects"] as? [[String: Any]])
        XCTAssertTrue(suspects.contains { $0["surface"] as? String == "Оксану" }, result.out)
        XCTAssertFalse(result.out.contains("example.org"))
        XCTAssertEqual(try files(), before)
    }

    func testRefusedInputHasNonzeroStatusAndNoRawFallback() throws {
        for json in [false, true] {
            let result = try run(["--text-file", "-"] + (json ? ["--json"] : []),
                                 stdin: "secret@example.org ⟦P1⟧")
            XCTAssertNotEqual(result.status, 0)
            XCTAssertFalse(result.out.contains("secret@example.org"))
            if json {
                let report = try object(result.out)
                XCTAssertEqual(report["wouldSend"] as? Bool, false)
                XCTAssertNil(report["text"])
                XCTAssertNotNil(report["refusal"])
            } else {
                XCTAssertEqual(result.out, "")
            }
        }
    }

    func testInvalidInputsFail() throws {
        for args in [[], ["--text-file", "-", "some-note"], ["--text-file", "/no-such-text-file"], ["missing-note"]] {
            XCTAssertNotEqual(try run(args).status, 0)
        }
        XCTAssertNotEqual(try run(["--text-file", "-"], stdin: " \n ").status, 0)
        let invalid = base.appendingPathComponent("invalid.txt")
        try Data([0xFF, 0xFE]).write(to: invalid)
        XCTAssertNotEqual(try run(["--text-file", invalid.path]).status, 0)
    }

    private func run(_ args: [String], stdin: String = "", privateMode: Bool = true) throws
        -> (out: String, err: String, status: Int32) {
        let task = Process()
        task.executableURL = binary
        task.arguments = ["depersonalize"] + args
        var env = ProcessInfo.processInfo.environment
        env["WIMM_BASE_DIR"] = base.path
        env["WIMM_TEST_MODE"] = "1"
        env["WIMM_DISABLE_KEYCHAIN"] = "1"
        env["WIMM_PRIVATE_MODE"] = privateMode ? "1" : "0"
        task.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = errors
        try task.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), task.terminationStatus)
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func files() throws -> [String: Data] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[url.path] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
