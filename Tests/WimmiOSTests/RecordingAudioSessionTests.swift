import XCTest
import AVFoundation
@testable import WimmiOSApp

final class RecordingAudioSessionTests: XCTestCase {
    func testBluetoothPreferenceAllowsHFPAndDoesNotPinMic() {
        let plan = RecordingAudioSession.plan(for: .bluetoothWhenConnected)
        XCTAssertEqual(plan.category, .record)
        XCTAssertEqual(plan.mode, .measurement)
        XCTAssertTrue(plan.options.contains(.allowBluetoothHFP))
        XCTAssertTrue(plan.options.contains(.duckOthers))
        XCTAssertFalse(plan.pinBuiltInMic)
    }

    func testBuiltInOnlyNeverAllowsBluetoothAndPinsMic() {
        let plan = RecordingAudioSession.plan(for: .builtInOnly)
        XCTAssertEqual(plan.category, .record)
        XCTAssertFalse(plan.options.contains(.allowBluetoothHFP))
        XCTAssertFalse(plan.options.contains(.allowBluetoothA2DP))
        XCTAssertTrue(plan.pinBuiltInMic)
    }

    func testPlansDifferOnlyInBluetoothChoice() {
        let bt = RecordingAudioSession.plan(for: .bluetoothWhenConnected)
        let builtIn = RecordingAudioSession.plan(for: .builtInOnly)
        XCTAssertEqual(bt.category, builtIn.category)
        XCTAssertEqual(bt.mode, builtIn.mode)
        XCTAssertEqual(bt.options.subtracting(.allowBluetoothHFP), builtIn.options)
    }

    func testPreferredPortPinsBuiltInOrPicksHeadset() {
        let bt = RecordingAudioSession.plan(for: .bluetoothWhenConnected)
        let builtIn = RecordingAudioSession.plan(for: .builtInOnly)
        let withAirPods: [AVAudioSession.Port] = [.builtInMic, .bluetoothHFP]
        XCTAssertEqual(RecordingAudioSession.preferredPort(for: builtIn, among: withAirPods), .builtInMic)
        XCTAssertEqual(RecordingAudioSession.preferredPort(for: bt, among: withAirPods), .bluetoothHFP)
        // Bluetooth wins over a wired headset; with only the iPhone mic iOS routes.
        XCTAssertEqual(RecordingAudioSession.preferredPort(for: bt, among: [.headsetMic, .builtInMic, .bluetoothHFP]), .bluetoothHFP)
        XCTAssertEqual(RecordingAudioSession.preferredPort(for: bt, among: [.builtInMic, .headsetMic]), .headsetMic)
        XCTAssertNil(RecordingAudioSession.preferredPort(for: bt, among: [.builtInMic]))
        XCTAssertNil(RecordingAudioSession.preferredPort(for: builtIn, among: []))
    }

    func testMicrophoneSwitchOfferedOnlyWhenItCanChangeSomething() {
        // Headset mode without any headset: nothing to switch.
        XCTAssertFalse(RecordingAudioSession.canSwitchMicrophone(
            preference: .bluetoothWhenConnected, availablePorts: [.builtInMic]))
        XCTAssertTrue(RecordingAudioSession.canSwitchMicrophone(
            preference: .bluetoothWhenConnected, availablePorts: [.builtInMic, .bluetoothHFP]))
        XCTAssertTrue(RecordingAudioSession.canSwitchMicrophone(
            preference: .bluetoothWhenConnected, availablePorts: [.builtInMic, .headsetMic]))
        // iPhone-only mode hides AirPods from the inputs, so the way back stays open.
        XCTAssertTrue(RecordingAudioSession.canSwitchMicrophone(
            preference: .builtInOnly, availablePorts: [.builtInMic]))
    }

    func testVoiceProcessingPlanKeepsMicChoice() {
        for preference in RecordingMicrophonePreference.allCases {
            let plain = RecordingAudioSession.plan(for: preference)
            let processed = RecordingAudioSession.plan(for: preference, voiceProcessing: true)
            // .measurement turns voice processing off; the trial needs a voice mode.
            XCTAssertEqual(plain.mode, .measurement)
            XCTAssertEqual(processed.mode, .videoChat)
            XCTAssertEqual(processed.category, .playAndRecord)
            XCTAssertEqual(processed.options, plain.options)
            XCTAssertEqual(processed.pinBuiltInMic, plain.pinBuiltInMic)
        }
    }

    func testVoiceIsolationIsOffByDefaultAndRoundTrips() throws {
        let suite = "wimm.tests.voice-isolation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(RecordingVoiceIsolationSetting.isEnabled(defaults: defaults))
        RecordingVoiceIsolationSetting.set(true, defaults: defaults)
        XCTAssertTrue(RecordingVoiceIsolationSetting.isEnabled(defaults: defaults))
    }

    func testPreferenceDefaultsToBluetoothAndRoundTrips() throws {
        let suite = "wimm.tests.mic-preference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(RecordingMicrophonePreference.load(from: defaults), .bluetoothWhenConnected)
        RecordingMicrophonePreference.builtInOnly.save(to: defaults)
        XCTAssertEqual(RecordingMicrophonePreference.load(from: defaults), .builtInOnly)
        defaults.set("garbage", forKey: RecordingMicrophonePreference.defaultsKey)
        XCTAssertEqual(RecordingMicrophonePreference.load(from: defaults), .bluetoothWhenConnected)
    }

    func testInputChangeSidecarValue() {
        let change = RecordingInputChange(offset: 12.345, name: "AirPods Pro",
                                          transport: AVAudioSession.Port.bluetoothHFP.rawValue,
                                          reason: "newDeviceAvailable")
        let value = change.sidecarValue
        XCTAssertEqual(value["offsetSeconds"] as? Double, 12.3)
        XCTAssertEqual(value["name"] as? String, "AirPods Pro")
        XCTAssertEqual(value["transport"] as? String, "BluetoothHFP")
        XCTAssertEqual(value["reason"] as? String, "newDeviceAvailable")
    }

    @MainActor
    func testStartCaptureRetryingSucceedsAfterTransientRefusalsWithFreshRecorders() async throws {
        var createdIDs: [Int] = []
        var cleanedIDs: [Int] = []
        var retriedAttempts: [Int] = []
        var sleptDelays: [TimeInterval] = []
        var nextID = 0

        let result = try await IOSAudioRecorder.startCaptureRetrying(
            sleep: { delay in sleptDelays.append(delay) },
            makeRecorder: {
                nextID += 1
                createdIDs.append(nextID)
                return nextID
            },
            start: { recorderID in recorderID >= 4 },
            cleanup: { recorderID in cleanedIDs.append(recorderID) },
            onRetry: { attempt in retriedAttempts.append(attempt) }
        )

        XCTAssertEqual(result?.recorder, 4)
        XCTAssertEqual(result?.attempts, 4)
        XCTAssertEqual(createdIDs, [1, 2, 3, 4])
        XCTAssertEqual(cleanedIDs, [1, 2, 3])
        XCTAssertEqual(retriedAttempts, [1, 2, 3])
        XCTAssertEqual(sleptDelays, [0.25, 0.25, 0.25])
    }

    @MainActor
    func testStartCaptureRetryingReturnsNilAfterExhausting3SecondWindow() async throws {
        var createdIDs: [Int] = []
        var cleanedIDs: [Int] = []
        var sleptDelays: [TimeInterval] = []
        var nextID = 0

        let result = try await IOSAudioRecorder.startCaptureRetrying(
            sleep: { delay in sleptDelays.append(delay) },
            makeRecorder: {
                nextID += 1
                createdIDs.append(nextID)
                return nextID
            },
            start: { _ in false },
            cleanup: { recorderID in cleanedIDs.append(recorderID) }
        )

        XCTAssertNil(result)
        XCTAssertEqual(createdIDs.count, 1 + IOSAudioRecorder.startRetryCount)
        XCTAssertEqual(cleanedIDs, createdIDs)
        XCTAssertEqual(sleptDelays.count, IOSAudioRecorder.startRetryCount)
        XCTAssertEqual(sleptDelays.reduce(0, +), 3.0, accuracy: 0.001)
    }

    @MainActor
    func testStartCaptureRetryingStopsImmediatelyOnCancellation() async throws {
        var createdIDs: [Int] = []
        var cleanedIDs: [Int] = []
        var nextID = 0

        let result = try await IOSAudioRecorder.startCaptureRetrying(
            sleep: { _ in throw CancellationError() },
            makeRecorder: {
                nextID += 1
                createdIDs.append(nextID)
                return nextID
            },
            start: { _ in false },
            cleanup: { recorderID in cleanedIDs.append(recorderID) }
        )

        XCTAssertNil(result)
        XCTAssertEqual(createdIDs, [1])
        XCTAssertEqual(cleanedIDs, [1])
    }
}
