import XCTest
@testable import WimmStudio

final class ExternalShoulderVoiceTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-commands-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func append(_ text: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func testOldCommandsAreNotReplayedAndNewOnesComeOnce() throws {
        try append("{\"action\":\"speak\",\"text\":\"старое\"}\n")
        var reader = AppendedLineReader(url: url)
        XCTAssertEqual(reader.next(), [])
        try append("{\"action\":\"stop\"}\n{\"action\":\"prepare\"}\n")
        XCTAssertEqual(reader.next(), ["{\"action\":\"stop\"}", "{\"action\":\"prepare\"}"])
        XCTAssertEqual(reader.next(), [])
    }

    func testHalfWrittenLineWaitsForItsEnd() throws {
        var reader = AppendedLineReader(url: url)
        try append("{\"action\":\"stop\"}\n{\"action\":\"spe")
        XCTAssertEqual(reader.next(), ["{\"action\":\"stop\"}"])
        try append("ak\",\"text\":\"Привет\"}\n")
        XCTAssertEqual(reader.next(), ["{\"action\":\"speak\",\"text\":\"Привет\"}"])
    }

    func testFileStartedOverIsReadFromItsBeginning() throws {
        try append("{\"action\":\"prepare\"}\n{\"action\":\"prepare\"}\n")
        var reader = AppendedLineReader(url: url)
        try Data("{\"action\":\"stop\"}\n".utf8).write(to: url)
        XCTAssertEqual(reader.next(), ["{\"action\":\"stop\"}"])
    }

    func testSpeakCommandDecodes() throws {
        let line = "{\"action\":\"speak\",\"id\":\"7\",\"turn\":\"t1\",\"index\":2,\"speaker\":\"demon\",\"text\":\"Да ладно.\",\"voice\":\"M5\",\"speed\":1.21}"
        let command = try JSONDecoder().decode(ShoulderVoiceCommand.self, from: Data(line.utf8))
        XCTAssertEqual(command, ShoulderVoiceCommand(action: "speak", id: "7", turn: "t1", index: 2,
                                                     speaker: "demon", text: "Да ладно.", voice: "M5", speed: 1.21))
    }
}
