import XCTest
@testable import WimmInfrastructure

final class AgentMarkStoreCacheTests: XCTestCase {
    private func mark(_ status: AgentMarkStore.Mark.Status) -> AgentMarkStore.Mark {
        .init(status: status, source: nil, comment: nil, markedAt: Date(timeIntervalSince1970: 1_000), noteId: "n",
              sidecarSHA256: nil, text: "t", analysis: "a")
    }

    func testReadsSeeEveryWriteEvenThroughAnotherStoreValue() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("marks-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let reader = AgentMarkStore(directory: directory), writer = AgentMarkStore(directory: directory)

        XCTAssertNil(reader.mark(forFile: "a.m4a"))
        try writer.update(["a.m4a": mark(.pending)])
        XCTAssertEqual(reader.mark(forFile: "a.m4a")?.status, .pending)
        XCTAssertEqual(reader.mark(forFile: "a.m4a")?.status, .pending) // served from the cache
        try writer.update(["a.m4a": mark(.applied), "b.m4a": mark(.noise)])
        XCTAssertEqual(reader.mark(forFile: "a.m4a")?.status, .applied)
        XCTAssertEqual(reader.mark(forFile: "b.m4a")?.status, .noise)
        try writer.update(["a.m4a": nil])
        XCTAssertNil(reader.mark(forFile: "a.m4a"))
    }
}
