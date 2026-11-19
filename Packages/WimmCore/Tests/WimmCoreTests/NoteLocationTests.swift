import ImageIO
import XCTest
@testable import WimmDomain
@testable import WimmInfrastructure

final class NoteLocationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteLocationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func sidecar(of note: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: FileStore.metadataURL(forRecordingURL: note))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSidecarRoundTripKeepsPlaceAndSource() throws {
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let location = try XCTUnwrap(NoteLocation(latitude: 48.20849, longitude: 16.37208, accuracy: 24.6,
                                                  source: .device, fixedAt: fixed))
        let read = try XCTUnwrap(NoteLocation(sidecarValue: location.sidecarValue))
        XCTAssertEqual(read.latitude, 48.20849, accuracy: 1e-6)
        XCTAssertEqual(read.longitude, 16.37208, accuracy: 1e-6)
        XCTAssertEqual(read.accuracy, 25)
        XCTAssertEqual(read.source, .device)
        XCTAssertEqual(read.fixedAt, fixed)
        XCTAssertEqual(read.displayString, "48.20849, 16.37208 (±25 m, device)")
    }

    func testImpossibleCoordinatesAreNoPlace() {
        XCTAssertNil(NoteLocation(latitude: 0, longitude: 0, source: .device))
        XCTAssertNil(NoteLocation(latitude: 91, longitude: 10, source: .media))
        XCTAssertNil(NoteLocation(latitude: .nan, longitude: 10, source: .media))
        XCTAssertNil(NoteLocation(sidecarValue: ["latitude": "48.2", "longitude": 16.3]))
    }

    func testStampMergesAndNeverReplacesAnExistingPlace() throws {
        let note = directory.appendingPathComponent("Wimm_2026-11-19_10-00-00.m4a")
        try Data("audio".utf8).write(to: note)
        try FileStore.mutateSidecar(at: FileStore.metadataURL(forRecordingURL: note)) { current in
            current["recordingId"] = "kept"
            return true
        }
        let first = try XCTUnwrap(NoteLocation(latitude: 48.2, longitude: 16.3, source: .device))
        let second = try XCTUnwrap(NoteLocation(latitude: 50.0, longitude: 14.4, source: .device))
        NoteLocation.stamp(first, for: note)
        NoteLocation.stamp(second, for: note)

        let stored = try sidecar(of: note)
        XCTAssertEqual(stored["recordingId"] as? String, "kept")
        XCTAssertEqual(NoteLocation(sidecarValue: stored[NoteLocation.metadataKey])?.latitude, 48.2)
        XCTAssertEqual(RecallSidecar(stored).location?.longitude, 16.3)
    }

    func testStampWritesNothingForANoteWhoseFileIsGone() throws {
        let note = directory.appendingPathComponent("Wimm_2026-11-19_10-00-01.m4a")
        let location = try XCTUnwrap(NoteLocation(latitude: 48.2, longitude: 16.3, source: .device))
        NoteLocation.stamp(location, for: note)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileStore.metadataURL(forRecordingURL: note).path))
    }

    func testPhotoGPSUsesHemisphereReferences() throws {
        let location = try XCTUnwrap(MediaLocation.location(gps: [
            kCGImagePropertyGPSLatitude: 33.8688,
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 70.6693,
            kCGImagePropertyGPSLongitudeRef: "W",
        ]))
        XCTAssertEqual(location.latitude, -33.8688)
        XCTAssertEqual(location.longitude, -70.6693)
        XCTAssertEqual(location.source, .media)
        XCTAssertEqual(location.displayString, "-33.86880, -70.66930 (from the media file)")
    }

    func testPhotoFileGPSIsReadAndAPlainImageHasNone() async throws {
        let tagged = directory.appendingPathComponent("tagged.jpg")
        let plain = directory.appendingPathComponent("plain.jpg")
        try writeJPEG(to: tagged, gps: [
            kCGImagePropertyGPSLatitude: 48.2085,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 16.3721,
            kCGImagePropertyGPSLongitudeRef: "E",
        ])
        try writeJPEG(to: plain, gps: nil)

        let location = await MediaLocation.read(fileAt: tagged)
        XCTAssertEqual(try XCTUnwrap(location).latitude, 48.2085, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(location).longitude, 16.3721, accuracy: 1e-4)
        XCTAssertEqual(MediaLocation.read(imageData: try Data(contentsOf: tagged))?.source, .media)
        let none = await MediaLocation.read(fileAt: plain)
        XCTAssertNil(none)
    }

    func testVideoLocationTag() {
        let location = MediaLocation.parse(iso6709: "+48.2085+016.3721+171.000/")
        XCTAssertEqual(location?.latitude, 48.2085)
        XCTAssertEqual(location?.longitude, 16.3721)
        XCTAssertEqual(MediaLocation.parse(iso6709: "-33.8688-070.6693/")?.longitude, -70.6693)
        XCTAssertNil(MediaLocation.parse(iso6709: "nowhere"))
    }

    func testShootingTimeUsesTheCameraOffsetAndRejectsAnUnsetClock() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shot = try XCTUnwrap(MediaOrigin.exifDate("2026:08:14 18:30:00", offset: "+02:00", now: now))
        XCTAssertEqual(ISO8601.string(from: shot), "2026-08-14T16:30:00Z")
        XCTAssertNotNil(MediaOrigin.exifDate("2026:08:14 18:30:00", offset: nil, now: now))
        XCTAssertNil(MediaOrigin.exifDate("1970:01:01 00:00:00", offset: "+00:00", now: now))
        XCTAssertNil(MediaOrigin.exifDate("2031:01:01 00:00:00", offset: "+00:00", now: now))
        XCTAssertNil(MediaOrigin.exifDate("no date", offset: nil, now: now))
    }

    func testPickedOriginalGivesPlaceAndShootingTime() async throws {
        let photo = directory.appendingPathComponent("shot.jpg")
        try writeJPEG(to: photo, gps: [
            kCGImagePropertyGPSLatitude: 48.2085,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 16.3721,
            kCGImagePropertyGPSLongitudeRef: "E",
        ], exif: [
            kCGImagePropertyExifDateTimeOriginal: "2025:08:14 18:30:00",
            kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
        ])
        let origin = MediaOrigin.read(imageData: try Data(contentsOf: photo))
        XCTAssertEqual(origin.place?.source, .media)
        XCTAssertEqual(origin.shotAt.map(ISO8601.string(from:)), "2025-08-14T16:30:00Z")
        let fromFile = await MediaOrigin.shotAt(fileAt: photo)
        XCTAssertEqual(fromFile, origin.shotAt)

        let text = directory.appendingPathComponent("letter.txt")
        try Data("Termin am 21.".utf8).write(to: text)
        let none = await MediaOrigin.shotAt(fileAt: text)
        XCTAssertNil(none)
    }

    func testAddedDateIsKeptNextToTheNoteDateAndReadsOlderKeys() throws {
        let note = directory.appendingPathComponent("Wimm_2025-08-14_18-30-00.jpg")
        try Data("image".utf8).write(to: note)
        let added = Date(timeIntervalSince1970: 1_800_000_000)
        NoteAddedDate.stamp(note, at: added)
        XCTAssertEqual(RecallSidecar(try sidecar(of: note)).addedAt, added)

        XCTAssertEqual(NoteAddedDate.read(metadata: ["origin": ["addedAt": ISO8601.string(from: added)]]), added)
        XCTAssertEqual(NoteAddedDate.read(metadata: ["shareSource": ["sharedAt": ISO8601.string(from: added)]]), added)
        XCTAssertNil(NoteAddedDate.read(metadata: ["origin": ["source": "studio-clipboard"]]))
    }

    private func writeJPEG(to url: URL, gps: [CFString: Any]?, exif: [CFString: Any]? = nil) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        var properties: [CFString: Any] = gps.map { [kCGImagePropertyGPSDictionary: $0] } ?? [:]
        if let exif { properties[kCGImagePropertyExifDictionary] = exif }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
