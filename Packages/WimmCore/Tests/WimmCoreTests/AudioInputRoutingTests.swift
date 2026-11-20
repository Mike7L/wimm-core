import XCTest
@testable import WimmInfrastructure

final class AudioInputRoutingTests: XCTestCase {
    private let builtIn = AudioInputOption(uid: "BuiltInMic", name: "MacBook Air Microphone", transport: "builtIn")
    private let airPods = AudioInputOption(uid: "AirPods-BT", name: "AirPods Pro von Mikhail", transport: "bluetooth")
    private let usbMic = AudioInputOption(uid: "USB-1", name: "USB Microphone", transport: "usb")

    func testPreferenceRawValueRoundTripAndDefaultsPersistence() {
        let suite = "wimm.audio-input-routing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AudioInputPreference.load(from: defaults), .systemDefault)
        XCTAssertEqual(AudioInputPreference(rawValue: "device:"), .systemDefault)
        XCTAssertEqual(AudioInputPreference(rawValue: "unexpected"), .systemDefault)

        for pref: AudioInputPreference in [.systemDefault, .builtInOnly, .device(uid: "AirPods-BT")] {
            let decoded = AudioInputPreference(rawValue: pref.rawValue)
            XCTAssertEqual(decoded, pref)
            pref.save(to: defaults)
            XCTAssertEqual(AudioInputPreference.load(from: defaults), pref)
        }
    }

    func testResolveRespectsPreferenceAndFallsBackWhenDisconnected() {
        let both = [builtIn, airPods]

        XCTAssertEqual(
            AudioInputRouting.resolve(preference: .systemDefault, available: both, systemDefaultUID: airPods.uid),
            airPods
        )
        XCTAssertEqual(
            AudioInputRouting.resolve(preference: .builtInOnly, available: both, systemDefaultUID: airPods.uid),
            builtIn
        )
        XCTAssertEqual(
            AudioInputRouting.resolve(preference: .device(uid: airPods.uid), available: both, systemDefaultUID: builtIn.uid),
            airPods
        )
        XCTAssertEqual(
            AudioInputRouting.resolve(preference: .device(uid: "missing"), available: [builtIn], systemDefaultUID: builtIn.uid),
            builtIn
        )
        XCTAssertNil(
            AudioInputRouting.resolve(preference: .builtInOnly, available: [], systemDefaultUID: nil)
        )
    }

    func testBoundDeviceUIDReturnsNilForSystemDefaultAndMissingDevices() {
        let both = [builtIn, airPods]

        XCTAssertNil(AudioInputRouting.boundDeviceUID(preference: .systemDefault, available: both, systemDefaultUID: airPods.uid))
        XCTAssertEqual(AudioInputRouting.boundDeviceUID(preference: .builtInOnly, available: both, systemDefaultUID: airPods.uid), builtIn.uid)
        XCTAssertEqual(AudioInputRouting.boundDeviceUID(preference: .device(uid: airPods.uid), available: both, systemDefaultUID: builtIn.uid), airPods.uid)
        XCTAssertNil(AudioInputRouting.boundDeviceUID(preference: .device(uid: airPods.uid), available: [builtIn], systemDefaultUID: builtIn.uid))
    }

    func testToggleTargetAndPreferenceAcrossAvailableDevices() {
        XCTAssertNil(AudioInputRouting.toggleTarget(current: builtIn, available: [builtIn]))
        XCTAssertNil(AudioInputRouting.toggledPreference(current: builtIn, available: [builtIn]))

        let two = [builtIn, airPods]
        XCTAssertEqual(AudioInputRouting.toggleTarget(current: builtIn, available: two), airPods)
        XCTAssertEqual(AudioInputRouting.toggledPreference(current: builtIn, available: two), .device(uid: airPods.uid))
        XCTAssertEqual(AudioInputRouting.toggleTarget(current: airPods, available: two), builtIn)
        XCTAssertEqual(AudioInputRouting.toggledPreference(current: airPods, available: two), .builtInOnly)

        // With USB + AirPods + Built-in: built-in prefers headset; any external switches back to built-in.
        let three = [builtIn, usbMic, airPods]
        XCTAssertEqual(AudioInputRouting.toggleTarget(current: builtIn, available: three), airPods)
        XCTAssertEqual(AudioInputRouting.toggleTarget(current: usbMic, available: three), builtIn)
        XCTAssertEqual(AudioInputRouting.toggleTarget(current: airPods, available: three), builtIn)
    }
}
