import XCTest
@testable import WimmInfrastructure

final class IdleModelRegistryTests: XCTestCase {
    private actor Releases {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }
    func testOnlyExpiredResourcesAreReleasedAndCanRegisterAgain() async {
        let registry = IdleModelRegistry(idleSeconds: 300, automaticallyTrim: false)
        let releases = Releases(), now = Date()
        await registry.record("old", at: now.addingTimeInterval(-301)) { await releases.add("old") }
        await registry.record("warm", at: now) { await releases.add("warm") }
        await registry.evict(force: false, now: now)
        let ids = await registry.ids, released = await releases.ids
        XCTAssertEqual(ids, ["warm"]); XCTAssertEqual(released, ["old"])
        await registry.record("old", at: now) { await releases.add("reloaded") }
        await registry.evict(force: true, now: now)
        let remaining = await registry.ids, all = await releases.ids
        XCTAssertTrue(remaining.isEmpty); XCTAssertEqual(Set(all), Set(["old", "warm", "reloaded"]))
    }
    func testPressureProtectsLiveParakeetButCanReleaseOtherIdleModels() async {
        let registry = IdleModelRegistry(automaticallyTrim: false)
        await registry.record("parakeet:ultra") {}
        await registry.record("diarizer") {}
        await registry.evict(force: true, protectedPrefix: "parakeet:")
        let ids = await registry.ids
        XCTAssertEqual(ids, ["parakeet:ultra"])
    }
    func testTouchProtectsWarmModelFromIdleEviction() async {
        let registry = IdleModelRegistry(idleSeconds: 300, automaticallyTrim: false)
        let now = Date()
        await registry.record("model", at: now.addingTimeInterval(-500)) {}
        await registry.touch("model", at: now)
        await registry.evict(force: false, now: now.addingTimeInterval(299))
        let ids = await registry.ids
        XCTAssertEqual(ids, ["model"])
    }
}
