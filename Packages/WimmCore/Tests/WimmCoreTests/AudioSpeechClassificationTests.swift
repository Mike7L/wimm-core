import XCTest
import WimmDomain
@testable import WimmInfrastructure

final class AudioSpeechClassificationTests: XCTestCase {
    func testCountAndSilenceAreDifferentEvidence() {
        XCTAssertNil(AudioSpeechLabel.speakerCount(0))
        XCTAssertNil(AudioSpeechLabel.speakerCount(-1))
        for (count, expected) in [(1, AudioSpeechLabel.onePerson), (2, .twoPeople), (3, .threeOrMore), (12, .threeOrMore)] {
            let metadata: [String: Any] = ["transcription": ["speakerTurns": ["speakers": count]]]
            XCTAssertEqual(AudioSpeechClassification.detected(in: metadata, speechStatus: .speech), expected)
        }
        XCTAssertNil(AudioSpeechClassification.detected(in: ["transcription": ["speakerTurns": ["speakers": 0]]], speechStatus: .speech))
        XCTAssertNil(AudioSpeechClassification.detected(in: [:], speechStatus: nil))
        XCTAssertEqual(AudioSpeechClassification.detected(in: [:], speechStatus: .noSpeech), .noSpeech)
    }

    func testExplicitNoSpeechWinsOverOldDetection() {
        let metadata: [String: Any] = ["transcription": [
            "speechClassification": ["label": "owner"], "speakerTurns": ["speakers": 3]]]
        XCTAssertEqual(AudioSpeechClassification.detected(in: metadata, speechStatus: .noSpeech), .noSpeech)
    }

    func testCorrectionDoesNotRewriteTextAndCanReturnToAutomatic() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.m4a")
        try Data([0]).write(to: file)
        FileStore.upsertMetadata(for: file, updates: ["recordingId": "keep", "transcription": [
            "transcript": "original words", "speechStatus": "speech", "speakerTurns": ["speakers": 2]]])
        func build() async -> Note {
            await NoteBuilder.build(file: file, index: 0, metaRepo: MetadataRepository(), transcriptRepo: TranscriptRepository())
        }
        try AudioSpeechClassification.setOverride(.owner, for: file)
        let corrected = await build()
        XCTAssertEqual(corrected.audioSpeechLabel, .owner)
        XCTAssertEqual(corrected.detectedAudioSpeechLabel, .twoPeople)
        XCTAssertEqual(corrected.text, "original words")
        let sidecar = FileStore.metadataURL(forRecordingURL: file)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        XCTAssertEqual(metadata["recordingId"] as? String, "keep")
        try AudioSpeechClassification.setOverride(nil, for: file)
        let automatic = await build()
        XCTAssertEqual(automatic.audioSpeechLabel, .twoPeople)
        XCTAssertNil(automatic.audioSpeechLabelOverride)
    }

    func testManualCorrectionSurvivesNewRunButDetectionDoesNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.m4a")
        FileStore.upsertMetadata(for: file, updates: ["audioSpeechLabelOverride": "owner", "transcription": [
            "transcript": "old", "speechClassification": ["label": "one_person"]]])
        recordRunSuccess(file: file, provider: "test", model: "test", audioDuration: nil,
                         startedAt: Date(), elapsedSeconds: 0, transcript: "new", speechStatus: .speech, rawResponse: nil)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: FileStore.metadataURL(forRecordingURL: file))) as? [String: Any])
        XCTAssertEqual(metadata["audioSpeechLabelOverride"] as? String, "owner")
        XCTAssertNil((metadata["transcription"] as? [String: Any])?[AudioSpeechClassification.key])
    }

    func testOwnerRequiresSeveralConsistentComparisons() {
        XCTAssertFalse(OwnerVoiceVerifier.accepted(scores: [0.9], threshold: 0.5))
        XCTAssertFalse(OwnerVoiceVerifier.accepted(scores: [0.9, 0.1], threshold: 0.5))
        XCTAssertFalse(OwnerVoiceVerifier.accepted(scores: [.nan, 0.9], threshold: 0.5))
        XCTAssertTrue(OwnerVoiceVerifier.accepted(scores: [0.6, 0.55], threshold: 0.5))
        XCTAssertTrue(OwnerVoiceVerifier.accepted(scores: [0.6, 0.6, 0.6, 0.6, 0.1], threshold: 0.5))
    }

    func testCorrectionDoesNotRecreateDeletedNote() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("deleted.m4a")
        try AudioSpeechClassification.setOverride(.owner, for: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: FileStore.metadataURL(forRecordingURL: file).path))
    }

    func testSpeakerRecordRoundTripsOwnerReceiptAndLegacyStillLoads() {
        let result = AudioSpeechClassification.Detection(label: .owner, ownerScore: 0.65, profileID: "local-profile")
        let record = SpeakerTurnsRecord(speakers: 1, engine: "test", turns: [], speechClassification: result)
        XCTAssertEqual(SpeakerTurnsRecord(sidecarValue: record.sidecarValue)?.speechClassification, result)
        XCTAssertNil(SpeakerTurnsRecord(sidecarValue: ["speakers": 1])?.speechClassification)
    }
}
