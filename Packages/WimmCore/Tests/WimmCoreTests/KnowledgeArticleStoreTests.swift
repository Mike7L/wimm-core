import Foundation
import XCTest
@testable import WimmInfrastructure

final class KnowledgeArticleStoreTests: XCTestCase {
    func testLoadsRecursivelySortsByFreshnessAndDerivesMetadata() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let older = root.appendingPathComponent("index.md")
        let newer = work.appendingPathComponent("wimm_app.md")
        try "# Главная\n\n> Короткое описание базы.\n".write(to: older, atomically: true, encoding: .utf8)
        try "# Wimm App\n\n| | |\n|---|---|\n\n---\n\n**Wimm** — персональная система знаний.\n".write(
            to: newer, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: newer.path)

        let articles = try await KnowledgeArticleStore(rootURL: root).loadArticles()

        XCTAssertEqual(articles.map(\.relativePath), ["work/wimm_app.md", "index.md"])
        XCTAssertEqual(articles[0].title, "Wimm App")
        XCTAssertEqual(articles[0].category, "work")
        XCTAssertEqual(articles[0].summary, "Wimm — персональная система знаний.")
        XCTAssertEqual(articles[1].summary, "Короткое описание базы.")
    }

    func testSaveIsAtomicAndRejectsStaleRevision() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("article.md")
        try "# Original\n\nBody".write(to: url, atomically: true, encoding: .utf8)

        let store = KnowledgeArticleStore(rootURL: root)
        let article = try await store.loadArticles().first!
        let saved = try await store.save(article, content: "# Updated\n\nNew body")
        XCTAssertEqual(saved.title, "Updated")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Updated\n\nNew body")

        try "# External\n\nSecretary change".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)
        do {
            _ = try await store.save(saved, content: "# Clobber")
            XCTFail("Expected stale revision protection")
        } catch let error as KnowledgeArticleStoreError {
            XCTAssertEqual(error, .articleChangedOnDisk)
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knowledge-article-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
