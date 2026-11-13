import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class NoteFingerprintSnapshotTests: XCTestCase {
    func testFreshnessAndBuildTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try "original".write(to: file, atomically: true, encoding: .utf8)
        FileStore.upsertMetadata(for: file, updates: ["transcription": ["transcript": "spoken"]])
        let before = NoteFingerprintSnapshot.stamps(for: file)
        let sidecar = try XCTUnwrap(RecallSidecar.load(forRecordingURL: file)).sidecar.dict
        let snapshot = try XCTUnwrap(NoteFingerprintSnapshot.capture(file: file, sidecar: sidecar, before: before))
        XCTAssertEqual(snapshot.current(for: file), NoteFingerprint.read(forRecordingURL: file))

        let note = RecallNote(id: "n", date: Date(), kind: "text", title: nil, summary: nil,
                              text: "original", filePath: file.path).withFingerprintSnapshot(snapshot)
        let encoded = RecallLibrary.Layout.encode(note)
        let layout = try JSONDecoder().decode(RecallLibrary.Layout.self, from: JSONEncoder().encode(encoded.layout))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(encoded.layout)) as? [String: Any])
        legacy.removeValue(forKey: "fingerprintSnapshot")
        let legacyLayout = try JSONDecoder().decode(RecallLibrary.Layout.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyLayout.fingerprintSnapshot)
        var builder = RecallLibrary.Builder()
        encoded.payload.withUnsafeBytes { builder.append(layout, payload: $0) }
        XCTAssertEqual(builder.build()[0].fingerprintSnapshot, snapshot)
        var copied = RecallLibrary.Builder()
        copied.append(0, of: builder.build())
        XCTAssertEqual(copied.build()[0].fingerprintSnapshot, snapshot)

        FileStore.upsertMetadata(for: file, updates: ["transcription": ["transcript": "changed"]])
        XCTAssertNil(snapshot.current(for: file))
        XCTAssertNil(NoteFingerprintSnapshot.capture(file: file, sidecar: sidecar, before: before))
        let freshMeta = try XCTUnwrap(RecallSidecar.load(forRecordingURL: file)).sidecar.dict
        let fresh = try XCTUnwrap(NoteFingerprintSnapshot.capture(file: file, sidecar: freshMeta,
                                                                 before: NoteFingerprintSnapshot.stamps(for: file)))
        try "edited".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertNil(fresh.current(for: file))
        let built = await LibraryRecallSource.build([file], includeFingerprints: true) { _, _, note in note }
        let actual = try XCTUnwrap(built.first ?? nil)
        XCTAssertEqual(actual.fingerprintSnapshot?.current(for: file), NoteFingerprint.read(forRecordingURL: file))
        let ordinary = await LibraryRecallSource.build([file]) { _, _, note in note }
        XCTAssertNil(try XCTUnwrap(ordinary.first ?? nil).fingerprintSnapshot)
    }
}
