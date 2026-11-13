import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class PersonalDocumentSyncTests: XCTestCase {
    private actor FakeCloud: PersonalDocumentSnapshotTransport {
        var info: PersonalDocumentSnapshotInfo?
        var text: Data?
        var publishes = 0
        var snapshotFetches = 0

        func publish(_ info: PersonalDocumentSnapshotInfo, text: Data) async throws {
            self.info = info
            self.text = text
            publishes += 1
        }

        func fetchInfo() async throws -> PersonalDocumentSnapshotInfo? { info }

        func fetchSnapshot() async throws -> (PersonalDocumentSnapshotInfo, Data)? {
            snapshotFetches += 1
            guard let info, let text else { return nil }
            return (info, text)
        }

        func corrupt() { text = Data("tampered".utf8) }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-document-sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDocument(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("me.md")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func publisher(_ cloud: FakeCloud, source: URL, cache: String = "mac") -> PersonalDocumentSync {
        PersonalDocumentSync(
            transport: cloud, role: .publisher(source: { source }),
            cache: PersonalDocumentSnapshotCache(directory: root.appendingPathComponent(cache)),
            deviceID: "mac-test"
        )
    }

    private func reader(_ cloud: FakeCloud) -> PersonalDocumentSync {
        PersonalDocumentSync(
            transport: cloud, role: .reader,
            cache: PersonalDocumentSnapshotCache(directory: root.appendingPathComponent("phone")),
            deviceID: "phone-test"
        )
    }

    func testPublishesOnlyWhenTheTextChanges() async throws {
        let cloud = FakeCloud()
        let url = try makeDocument("# Я\n\nПервый абзац [S1].\n")
        let mac = publisher(cloud, source: url)

        let first = try await mac.publishIfChanged()
        let second = try await mac.publishIfChanged()
        XCTAssertTrue(first)
        XCTAssertFalse(second)

        try Data("# Я\n\nВторой абзац [S2].\n".utf8).write(to: url)
        let third = try await mac.publishIfChanged()
        XCTAssertTrue(third)
        let publishes = await cloud.publishes
        let info = await cloud.info
        XCTAssertEqual(publishes, 2)
        XCTAssertEqual(info?.fileName, "me.md")
        XCTAssertEqual(info?.originDeviceId, "mac-test")
    }

    /// A Mac with no record of its last publish (fresh install, cleared
    /// library) asks the cloud before sending the same text again.
    func testDoesNotRepublishWhatTheCloudAlreadyHolds() async throws {
        let cloud = FakeCloud()
        let url = try makeDocument("# Я\n")
        _ = try await publisher(cloud, source: url, cache: "first").publishIfChanged()

        let again = try await publisher(cloud, source: url, cache: "second").publishIfChanged()
        XCTAssertFalse(again)
        let publishes = await cloud.publishes
        XCTAssertEqual(publishes, 1)
    }

    func testReaderKeepsTheLatestCopyAndSkipsAnUnchangedOne() async throws {
        let cloud = FakeCloud()
        let url = try makeDocument("# Я\n\nТекст.\n")
        let mac = publisher(cloud, source: url)
        let phone = reader(cloud)

        let empty = try await phone.refresh()
        XCTAssertFalse(empty)
        XCTAssertNil(phone.cache.load())

        _ = try await mac.publishIfChanged()
        let arrived = try await phone.refresh()
        XCTAssertTrue(arrived)
        XCTAssertEqual(phone.cache.load()?.text, "# Я\n\nТекст.\n")

        let unchanged = try await phone.refresh()
        XCTAssertFalse(unchanged)
        let fetches = await cloud.snapshotFetches
        XCTAssertEqual(fetches, 1, "an unchanged document must not download its text again")
    }

    func testReaderRejectsTextThatDoesNotMatchItsHash() async throws {
        let cloud = FakeCloud()
        _ = try await publisher(cloud, source: try makeDocument("# Я\n")).publishIfChanged()
        await cloud.corrupt()

        let phone = reader(cloud)
        do {
            _ = try await phone.refresh()
            XCTFail("a corrupted copy must not be stored")
        } catch {}
        XCTAssertNil(phone.cache.load())
    }

    func testPublisherWithoutADocumentDoesNothing() async throws {
        let cloud = FakeCloud()
        let mac = PersonalDocumentSync(
            transport: cloud, role: .publisher(source: { nil }),
            cache: PersonalDocumentSnapshotCache(directory: root), deviceID: "mac-test"
        )
        let published = try await mac.publishIfChanged()
        XCTAssertFalse(published)
        let publishes = await cloud.publishes
        XCTAssertEqual(publishes, 0)
    }

    func testInfoRoundTripsThroughTheSyncCoders() throws {
        let info = PersonalDocumentSnapshotInfo(
            sha256: "abc", byteCount: 3, fileName: "me.md",
            publishedAt: Date(timeIntervalSince1970: 1_800_000_000), originDeviceId: "mac"
        )
        let data = try JSONEncoder.wimmSyncEncoder.encode(info)
        let decoded = try JSONDecoder.wimmSyncDecoder.decode(PersonalDocumentSnapshotInfo.self, from: data)
        XCTAssertEqual(decoded, info)
        XCTAssertEqual(decoded.kind, PersonalDocumentSnapshotInfo.kind)
    }
}
