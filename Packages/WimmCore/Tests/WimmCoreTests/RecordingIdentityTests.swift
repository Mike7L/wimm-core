import XCTest
@testable import WimmDomain

final class RecordingIdentityTests: XCTestCase {
    func testHumanReadableLocalFilenameCarriesSeconds() throws {
        let id = try XCTUnwrap(UUID(uuidString: "6A03CBEF-1234-5678-9ABC-DEF012345678"))
        let createdAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-23T19:53:33Z")
        )
        let identity = RecordingIdentity(id: id, createdAt: createdAt)
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        XCTAssertEqual(
            identity.fileName(timeZone: berlin),
            "Wimm_2026-07-23_21-53-33_6A03CBEF.m4a"
        )
    }

    /// The library is ordered by filename and read as chronological order, so
    /// two captures a few seconds apart must sort by when they happened and not
    /// by their random id suffix.
    func testFilenamesInTheSameMinuteSortChronologically() throws {
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-23T19:53:00Z"))
        // "F..." would sort ahead of "0..." if the id decided the order.
        let earlier = RecordingIdentity(
            id: try XCTUnwrap(UUID(uuidString: "FFFFFFFF-1234-5678-9ABC-DEF012345678")),
            createdAt: base
        )
        let later = RecordingIdentity(
            id: try XCTUnwrap(UUID(uuidString: "00000000-1234-5678-9ABC-DEF012345678")),
            createdAt: base.addingTimeInterval(7)
        )

        XCTAssertLessThan(earlier.fileName(), later.fileName())
    }

    func testAvailableURLExpandsIdentityOnShortPrefixCollision() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let id = try XCTUnwrap(UUID(uuidString: "6A03CBEF-1234-5678-9ABC-DEF012345678"))
        let identity = RecordingIdentity(id: id, createdAt: Date(timeIntervalSince1970: 0))
        let first = DefaultFileStore.shared.newRecordingURL(
            identity: identity,
            in: base
        )
        try Data().write(to: first)

        let expanded = DefaultFileStore.shared.newRecordingURL(
            identity: identity,
            in: base
        )
        XCTAssertTrue(
            expanded.deletingPathExtension().lastPathComponent.hasSuffix("_6A03CBEF1234")
        )
    }

    /// Both shapes exist on disk: the minute-truncated one was written for a
    /// few days in July 2026 and those files are not renamed.
    func testRecordingDateParserAcceptsSecondAndMinuteFormats() {
        let withSeconds = URL(
            fileURLWithPath: "/tmp/Wimm_2026-07-23_21-53-33_6A03CBEF.m4a"
        )
        let minuteOnly = URL(
            fileURLWithPath: "/tmp/Wimm_2026-07-23_21-53_6A03CBEF.m4a"
        )
        let legacyEpochSuffix = URL(
            fileURLWithPath: "/tmp/Wimm_2026-07-23_21-53-33_1781553213722.m4a"
        )

        XCTAssertNotNil(FileStore.recordingDateFromFileName(withSeconds))
        XCTAssertNotNil(FileStore.recordingDateFromFileName(minuteOnly))
        XCTAssertNotNil(FileStore.recordingDateFromFileName(legacyEpochSuffix))
    }
}
