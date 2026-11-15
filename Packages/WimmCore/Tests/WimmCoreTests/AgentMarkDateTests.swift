import Foundation
import XCTest
@testable import WimmInfrastructure

final class AgentMarkDateTests: XCTestCase {
    func testFastPathMatchesISO8601Formatter() {
        let formatter = ISO8601DateFormatter()
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let date = Date(timeIntervalSince1970: TimeInterval(Int64.random(in: -2_000_000_000...4_000_000_000, using: &generator)))
            let string = formatter.string(from: date)
            XCTAssertEqual(AgentMarkStore.MarkDate.parseUTC(string), formatter.date(from: string), string)
        }
        for string in ["2024-02-29T23:59:59Z", "2000-02-29T00:00:00Z", "1970-01-01T00:00:00Z", "2026-12-31T12:30:45Z"] {
            XCTAssertEqual(AgentMarkStore.MarkDate.parseUTC(string), formatter.date(from: string), string)
        }
        for string in ["2023-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-11-15T03:16:53+01:00", "2026-11-15T03:16:53.5Z", "2026-11-15 03:16:53Z"] {
            XCTAssertNil(AgentMarkStore.MarkDate.parseUTC(string), string)
        }
    }

    func testMarksRoundTripWithOffsetDatesStillDecode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AgentMarkStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_763_175_413)
        try store.update(["a.txt": .init(status: .applied, source: "S1", markedAt: date, noteId: "n", text: "t", analysis: "a")])
        XCTAssertEqual(store.mark(forFile: "a.txt")?.markedAt, date)
        let json = #"{"schema":"AgentState@v1","marks":{"b.txt":{"status":"noise","markedAt":"2025-11-15T04:16:53+01:00","noteId":"n","text":"t","analysis":"a"}}}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("marks.json"))
        XCTAssertEqual(AgentMarkStore(directory: directory).mark(forFile: "b.txt")?.markedAt, date)
    }
}
