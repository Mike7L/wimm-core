import XCTest
@testable import WimmDomain

final class NoteAttachmentTests: XCTestCase {
    private struct RealMetaFixture: Decodable {
        let attachments: [NoteAttachment]
    }
    
    func testEncodingUsesRelativePath() throws {
        let base = FileStore.baseDirectory()
        let relativePath = "attachments/image.png"
        let fullURL = base.appendingPathComponent(relativePath)
        
        let attachment = NoteAttachment(
            id: UUID(),
            url: fullURL,
            type: .image
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(attachment)
        
        // Decode as dictionary to check the raw value of "url"
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertNotNil(json)
        
        let urlString = json?["url"] as? String
        XCTAssertEqual(urlString, relativePath, "Encoded JSON should contain relative path")
    }
    
    func testDecodingResolvesRelativePath() throws {
        let base = FileStore.baseDirectory()
        let relativePath = "docs/guide.pdf"
        let expectedURL = base.appendingPathComponent(relativePath)
        
        let jsonString = """
        {
            "id": "00000000-0000-0000-0000-000000000000",
            "url": "\(relativePath)",
            "type": "pdf"
        }
        """
        let data = jsonString.data(using: .utf8)!
        let decoder = JSONDecoder()
        let attachment = try decoder.decode(NoteAttachment.self, from: data)
        
        XCTAssertEqual(attachment.url.path, expectedURL.path, "Decoding should resolve relative path to absolute URL")
    }
    
    func testRoundTripPreservesData() throws {
        let base = FileStore.baseDirectory()
        let relativePath = "recordings/audio.m4a"
        let fullURL = base.appendingPathComponent(relativePath)
        
        let original = NoteAttachment(
            id: UUID(),
            url: fullURL,
            type: .audio,
            extractedText: "Some text",
            extractionProvider: "Apple",
            extractionModel: "v1"
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(original)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NoteAttachment.self, from: data)
        
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.url.path, original.url.path)
        XCTAssertEqual(decoded.typeEnum, original.typeEnum)
        XCTAssertEqual(decoded.extractedText, original.extractedText)
        XCTAssertEqual(decoded.extractionProvider, original.extractionProvider)
        XCTAssertEqual(decoded.extractionModel, original.extractionModel)
    }

    func testDecodingLegacyOCRKeysPopulatesUnifiedFields() throws {
        let base = FileStore.baseDirectory()
        let relativePath = "attachments/legacy.png"
        let expectedURL = base.appendingPathComponent(relativePath)

        let jsonString = """
        {
            "id": "00000000-0000-0000-0000-000000000000",
            "url": "\(relativePath)",
            "type": "image",
            "ocrText": "Hello from legacy",
            "ocrProvider": "legacy-provider",
            "ocrModel": "legacy-model"
        }
        """

        let data = try XCTUnwrap(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode(NoteAttachment.self, from: data)

        XCTAssertEqual(decoded.url.path, expectedURL.path)
        XCTAssertEqual(decoded.extractedText, "Hello from legacy")
        XCTAssertEqual(decoded.extractionProvider, "legacy-provider")
        XCTAssertEqual(decoded.extractionModel, "legacy-model")
    }

    func testEncodingWritesOnlyNewUnifiedKeys() throws {
        let base = FileStore.baseDirectory()
        let relativePath = "attachments/newkeys.png"
        let fullURL = base.appendingPathComponent(relativePath)

        let attachment = NoteAttachment(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            url: fullURL,
            type: .image,
            extractedText: "Hello",
            extractionProvider: "provider",
            extractionModel: "model"
        )

        let data = try JSONEncoder().encode(attachment)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(json["extractedText"])
        XCTAssertNotNil(json["extractionProvider"])
        XCTAssertNotNil(json["extractionModel"])

        XCTAssertNil(json["ocrText"])
        XCTAssertNil(json["ocrProvider"])
        XCTAssertNil(json["ocrModel"])
    }
    
    func testEncodingAbsoluteURLOutsideBase() throws {
        // If file is outside base, it should remain absolute
        let outsideURL = URL(fileURLWithPath: "/tmp/external.jpg")
        
        // Ensure /tmp is not base
        let base = FileStore.baseDirectory()
        guard !outsideURL.path.hasPrefix(base.path) else { return }
        
        let attachment = NoteAttachment(
            id: UUID(),
            url: outsideURL,
            type: .image
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(attachment)
        
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let urlString = json?["url"] as? String
        
        XCTAssertEqual(urlString, outsideURL.path, "Encoded JSON should contain absolute path for external files")
    }

    func testClipboardUniqueUUIDTextUsesAttachPattern() {
        let name = FileStore.attachmentFileNameForClipboardText(
            sessionID: "Wimm_2026-02-09_12-00-00",
            strategy: .uniqueUUID,
            uniqueSuffix: "unused"
        )

        XCTAssertTrue(name.contains("_Attach_"), "Clipboard text attachments must use _Attach_ naming")
        XCTAssertFalse(name.contains("_paste_"), "Clipboard text attachments must not use _paste_ naming")
        XCTAssertTrue(name.hasSuffix("_Text.txt"))
    }

    func testOpusIsRecognizedAsAudioExtension() {
        XCTAssertTrue(FileStore.supportedAudioExtensions.contains("opus"))

        let attachment = NoteAttachment(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/voice.opus"),
            type: "opus"
        )
        XCTAssertEqual(attachment.typeEnum, .audio)
    }

    func testRealNotes_2026_02_09_ClipboardAndOpusAttachments() throws {
        let fixtureNames = [
            "Wimm_2026-02-09_15-51-51.meta.json",
            "Wimm_2026-02-09_16-07-20.meta.json",
        ]

        for fixtureName in fixtureNames {
            let fixtureURL = realNotesFixtureURL(fixtureName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path), "Missing fixture: \(fixtureURL.path)")

            let data = try Data(contentsOf: fixtureURL)
            let fixture = try JSONDecoder().decode(RealMetaFixture.self, from: data)

            let textAttachment = try XCTUnwrap(fixture.attachments.first(where: { $0.type == "text" }))
            XCTAssertTrue(textAttachment.url.lastPathComponent.contains("_paste_"))
            XCTAssertEqual(textAttachment.extractionProvider, "clipboard")
            XCTAssertFalse((textAttachment.extractedText ?? "").isEmpty)

            let opusAttachment = try XCTUnwrap(fixture.attachments.first(where: { $0.type == "opus" }))
            XCTAssertEqual(opusAttachment.typeEnum, .audio)
            XCTAssertNil(opusAttachment.extractedText)
        }
    }

    private func realNotesFixtureURL(_ name: String, filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()  // file name
            .deletingLastPathComponent()  // WimmCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // WimmCore
            .deletingLastPathComponent()  // Packages
            .appendingPathComponent("Tests/TestAssets/real_notes", isDirectory: true)
            .appendingPathComponent(name)
    }
}
