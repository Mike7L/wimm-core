import Foundation
import WimmDomain
import XCTest

@testable import WimmInfrastructure

final class TranscriptionGlossaryTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-glossary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        unsetenv("WIMM_TEST_MODE")
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testProductionArtifactIsVersionedHashedAndNarrow() throws {
        let glossary = try XCTUnwrap(TranscriptionGlossary.production)

        XCTAssertEqual(glossary.schema, "TranscriptionGlossary@v1")
        XCTAssertEqual(glossary.version, "2026-07-28.ab-v3")
        XCTAssertEqual(glossary.protocolVersion, "context-v3")
        XCTAssertEqual(glossary.sha256.count, 64)
        XCTAssertEqual(glossary.entries.map(\.id), ["product.wimm", "ui.hud"])
        XCTAssertTrue(glossary.policy.canonicalizeOnlyWithMatchingContext)
        XCTAssertTrue(glossary.policy.preserveSpeakerNamingDeliberation)
    }

    func testNoteCardPayloadIncludesVersionedGlossaryEvidence() throws {
        let glossary = try XCTUnwrap(TranscriptionGlossary.production)
        let json = try LLMJSONClient.noteCardInputJSON(
            noteId: "note-1",
            transcript: "Открываю хад в Vim",
            localHypothesis: nil,
            lang: "ru",
            glossary: glossary,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let note = try XCTUnwrap(root["note"] as? [String: Any])
        let payload = try XCTUnwrap(note["glossary"] as? [String: Any])

        XCTAssertEqual(payload["version"] as? String, glossary.version)
        XCTAssertNil(payload["protocol_version"])
        XCTAssertNil(payload["sha256"])
        XCTAssertEqual((payload["entries"] as? [[String: Any]])?.count, 2)
        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertNotNil(entries[0]["evidence"])
        XCTAssertNotNil(entries[1]["evidence"])
    }

    func testNoteCardPayloadCanExplicitlyOmitGlossary() throws {
        let json = try LLMJSONClient.noteCardInputJSON(
            noteId: "note-1",
            transcript: "Plain transcript",
            localHypothesis: nil,
            lang: nil,
            glossary: nil,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let data = try XCTUnwrap(json.data(using: .utf8))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let note = try XCTUnwrap(root["note"] as? [String: Any])

        XCTAssertNil(note["glossary"])
    }

    func testSuccessfulNoteCardPersistsGlossaryReceipt() async throws {
        setenv("WIMM_TEST_MODE", "SUCCESS", 1)
        let glossary = try XCTUnwrap(TranscriptionGlossary.production)
        let file = tempDirectory.appendingPathComponent("note.m4a")
        try Data([0]).write(to: file)
        let metadataRepository = MetadataRepository()
        let processor = NoteProcessor(
            metadataRepository: metadataRepository,
            transcriptionGlossary: glossary,
            personalGlossaryStore: nil
        )

        _ = try await processor.makeNoteCard(
            file: file,
            transcript: "Открываю хад в Vim",
            lang: "ru"
        )

        let metadata = await metadataRepository.metadata(for: file)
        let receipt = try XCTUnwrap(
            metadata[MetadataKey.analysisGlossary.rawValue] as? [String: Any])
        XCTAssertEqual(receipt["version"] as? String, glossary.version)
        XCTAssertEqual(receipt["protocolVersion"] as? String, glossary.protocolVersion)
        XCTAssertEqual(receipt["sha256"] as? String, glossary.sha256)
    }

    func testProductionPromptContainsV3IntegrityContract() {
        let prompt = PromptLoader.load("transcription_note_card_extraction")

        XCTAssertTrue(prompt.contains("whole-token form listed literally"))
        XCTAssertTrue(prompt.contains("self-correction rule above remains authoritative"))
        XCTAssertTrue(prompt.contains("Neovim, .vimrc, plugins"))
    }
}
