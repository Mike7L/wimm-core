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
}
