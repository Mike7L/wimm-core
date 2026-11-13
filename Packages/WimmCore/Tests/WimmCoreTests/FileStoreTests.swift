import XCTest
@testable import WimmDomain

final class FileStoreTests: XCTestCase {
    
    func testRelativePathConversion() {
        let base = FileStore.baseDirectory()
        
        // Case 1: File inside base directory
        let fileInBase = base.appendingPathComponent("folder/test.txt")
        let relative = FileStore.relativePath(for: fileInBase)
        XCTAssertEqual(relative, "folder/test.txt", "Should return relative path for file inside base directory")
        
        // Case 2: File outside base directory
        // We use /tmp usually, ensuring it's not the base directory
        let fileOutside = URL(fileURLWithPath: "/tmp/outside.txt")
        let relativeOutside = FileStore.relativePath(for: fileOutside)
        
        // If the base directory happens to be /tmp (unlikely but possible in some CI), this test might be flaky.
        // But standard base is Application Support or Documents.
        if !fileOutside.path.hasPrefix(base.path) {
            XCTAssertEqual(relativeOutside, fileOutside.path, "Should return absolute path for file outside base directory")
        }
    }
    
    func testResolveRelativePath() {
        let base = FileStore.baseDirectory()
        
        // Case 1: Relative path
        let relativePath = "sub/file.json"
        let resolved = FileStore.resolveRelativePath(relativePath)
        let expected = base.appendingPathComponent(relativePath)
        XCTAssertEqual(resolved.path, expected.path, "Should resolve relative path against base directory")
        
        // Case 2: Absolute path
        let absolutePath = "/var/log/system.log"
        let resolvedAbsolute = FileStore.resolveRelativePath(absolutePath)
        XCTAssertEqual(resolvedAbsolute.path, absolutePath, "Should return absolute path as is")
        
        // Case 3: URL string (starts with file://) - FileStore.resolveRelativePath handles ://
        // "if path.hasPrefix("/") || path.contains("://")"
        let urlString = "file:///etc/hosts"
        let resolvedUrl = FileStore.resolveRelativePath(urlString)
        XCTAssertEqual(resolvedUrl.absoluteString, urlString, "Should handle URL strings as absolute paths")
    }

    func testUpsertMetadata_doesNotWriteRedundantKeys() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let rec = dir.appendingPathComponent("X.m4a")
        FileManager.default.createFile(atPath: rec.path, contents: Data())

        FileStore.upsertMetadata(for: rec, updates: [
            "createdAt": "2020-01-01T00:00:00Z",
            "importedAt": "2020-01-02T00:00:00Z",
            "duration": 123,
            "sourcePath": "/tmp/source.m4a",
            "document": [
                "createdAt": "2020-01-01T00:00:00Z",
                "importedAt": "2020-01-02T00:00:00Z",
                "duration": 123,
                "sourcePath": "/tmp/source.pdf",
                "pageCount": 3
            ]
        ])

        let metaURL = FileStore.metadataURL(forRecordingURL: rec)
        let data = try Data(contentsOf: metaURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["createdAt"])
        XCTAssertNil(json["importedAt"])
        XCTAssertNil(json["duration"])
        XCTAssertEqual(json["sourcePath"] as? String, "/tmp/source.m4a")

        let doc = json["document"] as? [String: Any]
        XCTAssertNotNil(doc)
        XCTAssertNil(doc?["createdAt"])
        XCTAssertNil(doc?["importedAt"])
        XCTAssertNil(doc?["duration"])
        XCTAssertEqual(doc?["sourcePath"] as? String, "/tmp/source.pdf")
        XCTAssertEqual(doc?["pageCount"] as? Int, 3)
    }

    func testSupportedDocumentExtensionsCoverRecognizedUploads() {
        for ext in ["pdf", "md", "markdown", "png", "jpg", "jpeg"] {
            XCTAssertTrue(
                FileStore.supportedDocumentExtensions.contains(ext),
                "\(ext) uploads should be indexed as supported documents"
            )
        }
    }

    func testRecordingDateFromFileNameParsesTimestampSuffix() {
        let url = URL(fileURLWithPath: "/tmp/Wimm_2026-05-28_20-04-06_1779991446854.m4a")
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: FileStore.recordingDateFromFileName(url) ?? Date.distantPast
        )

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 28)
        XCTAssertEqual(components.hour, 20)
        XCTAssertEqual(components.minute, 4)
        XCTAssertEqual(components.second, 6)
    }
    
    #if os(iOS)
    func testBaseDirectoryIOS() {
        // This test runs only on iOS target.
        // We verify that baseDirectory returns a valid URL and preferably inside an App Group or Documents.
        let base = FileStore.baseDirectory()
        XCTAssertTrue(base.path.count > 0)
        
        // Check if it is a directory (it might not exist yet, but the path should accept it)
        // FileStore.baseDirectory() doesn't create it, just returns the URL.
        
        // We can check if it looks like a valid app path.
        // Either contains "Group Containers" or "Documents" or "tmp"
        let path = base.path
        let validPaths = ["Group Containers", "Documents", "tmp", "Wimm"]
        let isValid = validPaths.contains { path.contains($0) }
        
        XCTAssertTrue(isValid, "Base directory on iOS should be in a standard location")
    }
    #endif
    
    // MARK: - allScreenshotURLs Tests
    
    private func makeTempDir() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-filestore-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }
    
    func testAllScreenshotURLs_findsLegacyHEIC() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let recording = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.m4a")
        let heic = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.heic")
        FileManager.default.createFile(atPath: heic.path, contents: Data("fake".utf8))
        
        let urls = FileStore.allScreenshotURLs(forRecordingURL: recording)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, "Wimm_2026-02-10_23-43-41.heic")
    }
    
    func testAllScreenshotURLs_findsMultiScreen() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let recording = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.m4a")
        for i in 1...3 {
            let screen = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41_screen\(i).heic")
            FileManager.default.createFile(atPath: screen.path, contents: Data("fake".utf8))
        }
        
        let urls = FileStore.allScreenshotURLs(forRecordingURL: recording)
        XCTAssertEqual(urls.count, 3)
        XCTAssertEqual(urls[0].lastPathComponent, "Wimm_2026-02-10_23-43-41_screen1.heic")
        XCTAssertEqual(urls[2].lastPathComponent, "Wimm_2026-02-10_23-43-41_screen3.heic")
    }
    
    func testAllScreenshotURLs_findsAttachmentScreenshots() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let recording = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.m4a")
        let attach = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41_Attach_screenshot_FAF732E5-A318-4812-8BC1-0C483102C170.heic")
        FileManager.default.createFile(atPath: attach.path, contents: Data("fake".utf8))
        
        let urls = FileStore.allScreenshotURLs(forRecordingURL: recording)
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls.first!.lastPathComponent.contains("_Attach_screenshot_"))
    }
    
    func testAllScreenshotURLs_prefersLegacyOverAttachment() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let recording = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.m4a")
        // Both legacy and attachment exist
        let heic = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.heic")
        let attach = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41_Attach_screenshot_AAA.heic")
        FileManager.default.createFile(atPath: heic.path, contents: Data("fake".utf8))
        FileManager.default.createFile(atPath: attach.path, contents: Data("fake".utf8))
        
        let urls = FileStore.allScreenshotURLs(forRecordingURL: recording)
        XCTAssertEqual(urls.count, 1, "Should only return legacy, not attachment")
        XCTAssertEqual(urls.first?.lastPathComponent, "Wimm_2026-02-10_23-43-41.heic")
    }
    
    func testAllScreenshotURLs_returnsEmptyWhenNoScreenshots() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        
        let recording = dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.m4a")
        
        let urls = FileStore.allScreenshotURLs(forRecordingURL: recording)
        XCTAssertTrue(urls.isEmpty)
    }

    // MARK: - Preview image shape

    func testPreviewImageSessionBase_recognizesPreviewShapes() {
        let dir = URL(fileURLWithPath: "/tmp")
        XCTAssertEqual(
            FileStore.previewImageSessionBase(dir.appendingPathComponent("Scan_20150518_111223.heic")),
            "Scan_20150518_111223"
        )
        XCTAssertEqual(
            FileStore.previewImageSessionBase(dir.appendingPathComponent("Wimm_2026-02-10_23-43-41_screen2.heic")),
            "Wimm_2026-02-10_23-43-41"
        )
        // Legacy screenshots were PNG.
        XCTAssertEqual(
            FileStore.previewImageSessionBase(dir.appendingPathComponent("Wimm_2026-02-10_23-43-41.png")),
            "Wimm_2026-02-10_23-43-41"
        )
        // Only heic/png are ever written as previews; a JPEG import is content.
        XCTAssertNil(FileStore.previewImageSessionBase(dir.appendingPathComponent("photo.jpg")))
        XCTAssertNil(FileStore.previewImageSessionBase(dir.appendingPathComponent("Scan_20150518_111223.pdf")))
        // "_screen" without an index is part of the name, not a screen suffix.
        XCTAssertEqual(
            FileStore.previewImageSessionBase(dir.appendingPathComponent("green_screen.heic")),
            "green_screen"
        )
    }

    func testIsDerivedPreviewImage_onlyMatchesItsOwnSession() {
        let dir = URL(fileURLWithPath: "/tmp")
        let preview = dir.appendingPathComponent("Scan_20150518_111223.heic")
        XCTAssertTrue(FileStore.isDerivedPreviewImage(preview, sessionBase: "Scan_20150518_111223"))
        XCTAssertFalse(FileStore.isDerivedPreviewImage(preview, sessionBase: "Scan_20150518_111224"))
    }
}
