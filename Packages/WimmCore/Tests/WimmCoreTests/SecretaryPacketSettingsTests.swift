import Foundation
import XCTest
@testable import WimmSecretary

final class SecretaryPacketSettingsTests: XCTestCase {
    func testDefaultAndPersistedBudgetStayWithinSliderRange() throws {
        let name = "secretary-packet-settings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(SecretaryPacketSettings.preferredKB(defaults: defaults), 512)
        defaults.set(1024, forKey: SecretaryPacketSettings.defaultsKey)
        XCTAssertEqual(SecretaryPacketSettings.preferredKB(defaults: defaults), 1024)
        defaults.set(-100, forKey: SecretaryPacketSettings.defaultsKey)
        XCTAssertEqual(SecretaryPacketSettings.preferredKB(defaults: defaults), 64)
        defaults.set(Int.max, forKey: SecretaryPacketSettings.defaultsKey)
        XCTAssertEqual(SecretaryPacketSettings.preferredKB(defaults: defaults), 1024)
        defaults.set("bad", forKey: SecretaryPacketSettings.defaultsKey)
        XCTAssertEqual(SecretaryPacketSettings.preferredKB(defaults: defaults), 512)
        XCTAssertEqual(SecretaryPacketSettings.normalize(510), 512)
    }
}
