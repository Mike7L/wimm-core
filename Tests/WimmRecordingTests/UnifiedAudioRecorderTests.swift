import XCTest
import Combine
import AVFoundation
@testable import WimmRecording
import WimmDomain
import WimmInfrastructure

final class UnifiedAudioRecorderTests: XCTestCase {
    
    private var testBase: URL!
    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    
    override func setUp() async throws {
        // Create isolated test directory
        testBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wimm-recording-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: testBase, withIntermediateDirectories: true)
        setenv("WIMM_BASE_DIR", testBase.path, 1)
    }
    
    override func tearDown() async throws {
        unsetenv("WIMM_BASE_DIR")
        try? fileManager.removeItem(at: testBase)
        cancellables.removeAll()
    }
    
    @MainActor
    func testInitialization() {
        let recorder = UnifiedAudioRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(recorder.duration, 0)
    }
    
    @MainActor
    func testStartStopRecording() async throws {
        try requireMicrophoneTests()
        let recorder = UnifiedAudioRecorder()
        let url = try await recorder.startRecording()
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(fileManager.fileExists(atPath: url.path))
        try await Task.sleep(for: .milliseconds(200))
        let stopURL = try await recorder.stopRecording()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(url, stopURL)
        XCTAssertTrue(fileManager.fileExists(atPath: stopURL.path))
    }

    @MainActor
    func testLevelsPublisher() async throws {
        try requireMicrophoneTests()
        let recorder = UnifiedAudioRecorder()
        let levelsExpectation = XCTestExpectation(description: "Receive levels")
        let bufferExpectation = XCTestExpectation(description: "Receive audio buffer")
        levelsExpectation.assertForOverFulfill = false
        bufferExpectation.assertForOverFulfill = false
        recorder.audioLevelsPublisher
            .sink { levels in
                if !levels.isEmpty { levelsExpectation.fulfill() }
            }
            .store(in: &cancellables)
        let consumerID = recorder.addRecordingAudioBufferConsumer { _, _ in
            bufferExpectation.fulfill()
        }
        defer { recorder.removeRecordingAudioBufferConsumer(consumerID) }
        _ = try await recorder.startRecording()
        let result = await XCTWaiter().fulfillment(of: [levelsExpectation, bufferExpectation], timeout: 2.0)
        _ = try await recorder.stopRecording()
        XCTAssertEqual(result, .completed, "Microphone must publish both levels and audio buffers")
    }

    private func requireMicrophoneTests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WIMM_MICROPHONE_TESTS"] == "1",
                          "Set WIMM_MICROPHONE_TESTS=1 to run hardware checks")
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          "Microphone access must be granted before hardware checks")
    }
}
