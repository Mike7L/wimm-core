import XCTest
@testable import WimmInfrastructure
@testable import WimmDomain

final class RecordingsDirectoryIndexTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingsDirectoryIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: tempDir.appendingPathComponent(name))
    }

    private func recording(_ name: String) -> URL {
        tempDir.appendingPathComponent(name)
    }

    /// The index must return exactly what the filesystem-based path returns.
    private func assertMatchesFileStore(_ recordingURL: URL, file: StaticString = #filePath, line: UInt = #line) {
        let index = RecordingsDirectoryIndex(directories: [tempDir])
        let expected = FileStore.allScreenshotURLs(forRecordingURL: recordingURL).first
        let actual = index.firstScreenshotURL(forRecordingURL: recordingURL)
        XCTAssertEqual(actual?.lastPathComponent, expected?.lastPathComponent, file: file, line: line)
    }

    func testNoScreenshots() throws {
        try touch("Wimm_2026-01-01_10-00-00.m4a")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.m4a"))
    }

    func testMainScreenshotPreferred() throws {
        try touch("Wimm_2026-01-01_10-00-00.m4a")
        try touch("Wimm_2026-01-01_10-00-00.heic")
        try touch("Wimm_2026-01-01_10-00-00_screen1.heic")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.m4a"))
    }

    func testMultiScreenFallback() throws {
        try touch("Wimm_2026-01-01_10-00-00.m4a")
        try touch("Wimm_2026-01-01_10-00-00_screen1.heic")
        try touch("Wimm_2026-01-01_10-00-00_screen2.heic")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.m4a"))
    }

    func testAttachScreenshotFallbackPicksFirstSorted() throws {
        try touch("Wimm_2026-01-01_10-00-00.m4a")
        try touch("Wimm_2026-01-01_10-00-00_Attach_screenshot_BBBB.heic")
        try touch("Wimm_2026-01-01_10-00-00_Attach_screenshot_AAAA.heic")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.m4a"))
    }

    func testAttachIgnoredWhenScreenExists() throws {
        try touch("Wimm_2026-01-01_10-00-00.m4a")
        try touch("Wimm_2026-01-01_10-00-00_screen1.heic")
        try touch("Wimm_2026-01-01_10-00-00_Attach_screenshot_AAAA.heic")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.m4a"))
    }

    func testAttachOfOtherSessionNotPickedUp() throws {
        try touch("Wimm_2026-01-01_10-00-00.m4a")
        try touch("Wimm_2026-01-01_11-11-11_Attach_screenshot_AAAA.heic")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.m4a"))
    }

    func testTxtNoteWithoutSidecars() throws {
        try touch("Wimm_2026-01-01_10-00-00.txt")
        assertMatchesFileStore(recording("Wimm_2026-01-01_10-00-00.txt"))
    }

    func testUncoveredDirectoryReportsNotCovered() throws {
        let index = RecordingsDirectoryIndex(directories: [tempDir])
        let foreign = FileManager.default.temporaryDirectory
            .appendingPathComponent("other-\(UUID().uuidString)")
            .appendingPathComponent("Wimm_2026-01-01_10-00-00.m4a")
        XCTAssertFalse(index.covers(directoryOf: foreign))
        XCTAssertNil(index.firstScreenshotURL(forRecordingURL: foreign))
        XCTAssertTrue(index.covers(directoryOf: recording("x.m4a")))
    }
}
