import XCTest
@testable import WimmStudio

final class ShouldersMemoryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shoulders-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("shoulders"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ id: String, _ text: String, minutesAgo: Double) throws {
        let url = directory.appendingPathComponent("shoulders/\(id).md")
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: url.path)
    }

    private let talk = "😇: Привет.\n\n**Пользователь:** Завтра позвоню Лёве.\n\n😈: Ну-ну.\n"

    func testNoMemoryAndNothingPendingInAnEmptyFolder() {
        XCTAssertNil(ShouldersMemory.text(in: directory))
        XCTAssertEqual(ShouldersMemory.pending(excluding: "now", in: directory), .init())
    }

    func testPendingTakesAnsweredConversationsOldestFirstAndSkipsTheRest() throws {
        try write("old", talk, minutesAgo: 30)
        try write("new", "😇: Привет.\n\n**Ты [note: a.m4a]:** Не позвонил.\n", minutesAgo: 10)
        try write("silent", "# Ангел и Демон\n\n😇: Привет.\n", minutesAgo: 5)
        try write("now", talk, minutesAgo: 0)

        let pending = ShouldersMemory.pending(excluding: "now", in: directory)
        XCTAssertEqual(pending.take.map(\.id), ["old", "new"])
        XCTAssertEqual(pending.skip, ["silent"])
    }

    func testOnlyTheNewestConversationsAreRead() throws {
        for index in 0..<7 { try write("c\(index)", talk, minutesAgo: Double(70 - index * 10)) }
        let pending = ShouldersMemory.pending(excluding: "now", in: directory)
        XCTAssertEqual(pending.take.map(\.id), ["c2", "c3", "c4", "c5", "c6"])
        XCTAssertEqual(pending.skip, ["c0", "c1"])
    }

    func testAnOversizeConversationIsSkippedNotCut() throws {
        try write("huge", talk + String(repeating: "я", count: ShouldersMemory.maxCharacters), minutesAgo: 10)
        try write("small", talk, minutesAgo: 20)
        let pending = ShouldersMemory.pending(excluding: "now", in: directory)
        XCTAssertEqual(pending.take.map(\.text), [talk])
        XCTAssertEqual(pending.skip, ["huge"])
    }

    func testStoreKeepsTheOldMemoryAndSettlesTheConversations() throws {
        try write("a", talk, minutesAgo: 20)
        try write("b", talk, minutesAgo: 10)
        try ShouldersMemory.store("Обещал:\n«позвоню Лёве»", covering: ["a"], in: directory)
        XCTAssertEqual(ShouldersMemory.text(in: directory), "Обещал:\n«позвоню Лёве»")
        XCTAssertEqual(ShouldersMemory.pending(excluding: "now", in: directory).take.map(\.id), ["b"])

        try ShouldersMemory.store("Обещал:\n—", covering: ["b"], in: directory)
        ShouldersMemory.markSeen(["c"], in: directory)
        XCTAssertEqual(ShouldersMemory.seen(in: directory), ["a", "b", "c"])
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("shoulders_memory.previous.md"), encoding: .utf8),
                       "Обещал:\n«позвоню Лёве»\n")
        XCTAssertEqual(ShouldersMemory.pending(excluding: "now", in: directory), .init())
    }

    func testRequestAndPromptBlockCarryDatesAndTheMemory() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 22, minute: 5)))
        let request = ShouldersMemory.rewriteRequest(memory: nil, transcripts: [.init(id: "a", date: date, text: talk)])
        XCTAssertTrue(request.hasPrefix("# Прежняя память\n\n(пусто)\n\n# Разговор 2026-11-19 22:05\n\n😇: Привет."))

        let block = ShouldersMemory.promptBlock(memory: "Счёт:\nАнгел 1 : Демон 0", today: date)
        XCTAssertTrue(block.contains("Сегодня 2026-11-19."))
        XCTAssertTrue(block.hasSuffix("Счёт:\nАнгел 1 : Демон 0"))
    }
}
