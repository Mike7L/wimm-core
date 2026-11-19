import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class DeviceLogSyncTests: XCTestCase {
    private actor FakeCloud: DeviceLogTransport {
        var devices: [String] = []
        var indexes: [String: DeviceLogIndex] = [:]
        var files: [String: Data] = [:]
        var uploads: [String] = []
        var deletes: [String] = []

        func fetchDevices() async throws -> [String] { devices }
        func registerDevice(_ deviceID: String) async throws {
            if !devices.contains(deviceID) { devices.append(deviceID) }
        }
        func fetchIndex(deviceID: String) async throws -> DeviceLogIndex? { indexes[deviceID] }
        func publishIndex(_ index: DeviceLogIndex) async throws { indexes[index.deviceID] = index }
        func uploadFile(deviceID: String, name: String, data: Data) async throws {
            files["\(deviceID)/\(name)"] = data
            uploads.append(name)
        }
        func downloadFile(deviceID: String, name: String) async throws -> Data? { files["\(deviceID)/\(name)"] }
        func deleteFiles(deviceID: String, names: [String]) async throws {
            for name in names { files["\(deviceID)/\(name)"] = nil }
            deletes += names
        }
    }

    private final class Flag: @unchecked Sendable { var on = false }

    private var root: URL!
    private let today: Date = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 19; parts.hour = 12
        return Calendar.current.date(from: parts)!
    }()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-device-logs-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var events: URL { root.appendingPathComponent("phone/events") }

    private func writeLog(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: events.appendingPathComponent(name))
    }

    private func phone(_ cloud: FakeCloud, privateMode: Flag = Flag()) -> DeviceLogSync {
        DeviceLogSync(
            transport: cloud, role: .uploader,
            eventsDirectory: events,
            stateDirectory: root.appendingPathComponent("phone/sync"),
            collectDirectory: root.appendingPathComponent("phone/devices"),
            deviceID: "phone-1", deviceLabel: "iPhone17,1-phone-1",
            now: { [today] in today }, privateMode: { privateMode.on }
        )
    }

    private func mac(_ cloud: FakeCloud) -> DeviceLogSync {
        DeviceLogSync(
            transport: cloud, role: .collector,
            eventsDirectory: root.appendingPathComponent("mac/events"),
            stateDirectory: root.appendingPathComponent("mac/sync"),
            collectDirectory: root.appendingPathComponent("mac/devices"),
            deviceID: "mac-1", now: { [today] in today }, privateMode: { false }
        )
    }

    func testUploadsRecentDaysOnlyAndOnlyChangedFiles() async throws {
        try writeLog("events_2026-11-19.jsonl", "{\"a\":1}\n")
        try writeLog("events_2026-11-17.jsonl", "{\"b\":2}\n")
        try writeLog("events_2026-11-10.jsonl", "{\"old\":true}\n")
        try writeLog("notes.txt", "not a log")
        let cloud = FakeCloud()
        let sync = phone(cloud)

        let first = try await sync.upload()
        XCTAssertEqual(first, ["events_2026-11-17.jsonl", "events_2026-11-19.jsonl"])
        let devices = await cloud.devices
        XCTAssertEqual(devices, ["phone-1"])

        let unchanged = try await sync.upload()
        XCTAssertEqual(unchanged, [])

        try writeLog("events_2026-11-19.jsonl", "{\"a\":1}\n{\"a\":2}\n")
        let grown = try await sync.upload()
        XCTAssertEqual(grown, ["events_2026-11-19.jsonl"])
    }

    func testMacCollectsDecompressedCopies() async throws {
        let text = String(repeating: "{\"event\":\"recording.saved\"}\n", count: 200)
        try writeLog("events_2026-11-19.jsonl", text)
        let cloud = FakeCloud()
        try await phone(cloud).upload()

        let packed = await cloud.files["phone-1/events_2026-11-19.jsonl"]
        XCTAssertLessThan(packed?.count ?? .max, text.utf8.count)

        let written = try await mac(cloud).collect()
        XCTAssertEqual(written.map(\.lastPathComponent), ["events_2026-11-19.jsonl"])
        let copy = root.appendingPathComponent("mac/devices/iPhone17,1-phone-1/events_2026-11-19.jsonl")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), text)

        let again = try await mac(cloud).collect()
        XCTAssertEqual(again, [], "an unchanged file is not downloaded again")
    }

    func testPrivateModeSendsNothing() async throws {
        try writeLog("events_2026-11-19.jsonl", "{\"a\":1}\n")
        let cloud = FakeCloud()
        let flag = Flag()
        flag.on = true
        let sent = try await phone(cloud, privateMode: flag).upload()
        XCTAssertEqual(sent, [])
        let uploads = await cloud.uploads
        XCTAssertTrue(uploads.isEmpty)
    }

    func testExpiredFilesLeaveTheCloud() async throws {
        let cloud = FakeCloud()
        try await cloud.publishIndex(DeviceLogIndex(deviceID: "phone-1", deviceLabel: "x", files: [
            DeviceLogFile(name: "events_2026-10-01.jsonl", sha256: "s", byteCount: 1, uploadedAt: today),
        ]))
        try writeLog("events_2026-11-19.jsonl", "{\"a\":1}\n")
        try await phone(cloud).upload()

        let deletes = await cloud.deletes
        XCTAssertEqual(deletes, ["events_2026-10-01.jsonl"])
        let index = await cloud.indexes["phone-1"]
        XCTAssertEqual(index?.files.map(\.name), ["events_2026-11-19.jsonl"])
    }

    func testThrottleSkipsRepeatedRuns() async throws {
        try writeLog("events_2026-11-19.jsonl", "{\"a\":1}\n")
        let cloud = FakeCloud()
        let sync = phone(cloud)
        await sync.syncNow()
        try writeLog("events_2026-11-19.jsonl", "{\"a\":1}\n{\"a\":2}\n")
        await sync.syncNow()
        var uploads = await cloud.uploads
        XCTAssertEqual(uploads.count, 1)
        await sync.syncNow(force: true)
        uploads = await cloud.uploads
        XCTAssertEqual(uploads.count, 2)
    }
}
