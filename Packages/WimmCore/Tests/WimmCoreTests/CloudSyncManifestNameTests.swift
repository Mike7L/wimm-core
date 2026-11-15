import XCTest
@testable import WimmInfrastructure

/// A manifest from iCloud names the files of a note. A name that is a path
/// (or `.`, `..`, empty) would write outside the recordings folder.
final class CloudSyncManifestNameTests: XCTestCase {
    private func file(_ name: String, role: RecordingBundleFileRole = .attachment) -> RecordingBundleFile {
        RecordingBundleFile(role: role, relativePath: name, fileName: name, byteSize: 1, modifiedAt: Date())
    }

    func testPlainNamesMapAsBefore() {
        XCTAssertEqual(
            CloudRecordingSyncService.localFileName(for: file("Rec_A.m4a", role: .primary), remoteBase: "Rec_A", localBase: "Rec_B"),
            "Rec_B.m4a")
        XCTAssertEqual(
            CloudRecordingSyncService.localFileName(for: file("Rec_A.meta.json", role: .metadata), remoteBase: "Rec_A", localBase: "Rec_B"),
            "Rec_B.meta.json")
        XCTAssertEqual(
            CloudRecordingSyncService.localFileName(for: file("photo.jpg"), remoteBase: "Rec_A", localBase: "Rec_B"),
            "Rec_B_Attach_photo.jpg")
    }

    func testPathLikeNamesAreRejected() {
        for name in ["", ".", "..", "../evil.m4a", "Rec_A/../../evil", "/tmp/evil", "sub/photo.jpg", "dir/"] {
            for role in [RecordingBundleFileRole.primary, .metadata, .attachment, .screenshot, .mini, .other] {
                XCTAssertNil(
                    CloudRecordingSyncService.localFileName(for: file(name, role: role), remoteBase: "Rec_A", localBase: "Rec_A"),
                    "\(role) \(name)")
            }
        }
    }

    func testUnsafeBaseIsRejectedToo() {
        for role in [RecordingBundleFileRole.metadata, .attachment, .screenshot, .other] {
            XCTAssertNil(CloudRecordingSyncService.localFileName(
                for: file("a.m4a", role: role), remoteBase: "Rec_A", localBase: "../evil"), "\(role)")
        }
        XCTAssertNil(CloudRecordingSyncService.localFileName(
            for: file("../x.m4a", role: .primary), remoteBase: "../x", localBase: "Rec"))
    }
}
