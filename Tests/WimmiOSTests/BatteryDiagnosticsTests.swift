import XCTest
@testable import WimmiOSApp

final class BatteryDiagnosticsTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "BatteryDiagnosticsTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testEverythingIsOffByDefault() {
        let s = BatteryDiagnosticsSettings(defaults: freshDefaults())
        XCTAssertEqual(s, BatteryDiagnosticsSettings())
        XCTAssertFalse(s.log)
        XCTAssertFalse(s.disableLiveText)
        XCTAssertFalse(s.disableLevelMeter)
        XCTAssertFalse(s.quietLiveLog)
        XCTAssertFalse(s.slowAutosave)
        XCTAssertEqual(s.autosaveInterval, 5, "default autosave cadence must stay 5 s")
        XCTAssertEqual(s.variant, "default")
    }

    func testSwitchesAreReadFromDefaults() {
        let d = freshDefaults()
        d.set(true, forKey: BatteryDiagnosticsSettings.logKey)
        d.set(true, forKey: BatteryDiagnosticsSettings.disableLiveTextKey)
        d.set(true, forKey: BatteryDiagnosticsSettings.slowAutosaveKey)
        let s = BatteryDiagnosticsSettings(defaults: d)
        XCTAssertTrue(s.log)
        XCTAssertTrue(s.disableLiveText)
        XCTAssertFalse(s.disableLevelMeter)
        XCTAssertEqual(s.autosaveInterval, 60)
        XCTAssertEqual(s.variant, "noLive+slowSave")
    }

    func testCPUPercent() {
        XCTAssertEqual(BatterySample.cpuPercent(previousCPU: 10, currentCPU: 16, wallSeconds: 60)!, 10, accuracy: 0.001)
        XCTAssertNil(BatterySample.cpuPercent(previousCPU: 10, currentCPU: 16, wallSeconds: 0))
        XCTAssertNil(BatterySample.cpuPercent(previousCPU: 16, currentCPU: 10, wallSeconds: 60))
    }

    func testBatteryPercent() {
        XCTAssertNil(BatterySample.batteryPercent(fromLevel: -1))
        XCTAssertEqual(BatterySample.batteryPercent(fromLevel: 0.87), 87)
    }

    func testCSVLineMatchesHeader() {
        let sample = BatterySample(
            time: Date(timeIntervalSince1970: 0), phase: "recording", variant: "default",
            elapsed: 120, batteryPercent: nil, batteryState: "unplugged", lowPower: false,
            thermal: "nominal", appState: "bg", brightness: 0.5, input: "Bluetooth, HFP",
            cpuSeconds: 12.345, cpuPercent: 7.26, livePartials: 30, liveRestarts: 2
        )
        let fields = sample.csvLine.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields.count, BatterySample.csvHeader.split(separator: ",").count)
        XCTAssertEqual(fields[4], "", "unknown battery level stays empty")
        XCTAssertEqual(fields[10], "Bluetooth  HFP", "commas in the route never split a column")
        XCTAssertEqual(fields[12], "7.3")
    }
}
