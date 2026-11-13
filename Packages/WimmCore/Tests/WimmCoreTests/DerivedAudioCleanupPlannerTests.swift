import XCTest
import WimmInfrastructure

final class DerivedAudioCleanupPlannerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DerivedCleanup_" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func make(_ name: String, in directory: URL? = nil, bytes: Int = 8) throws -> URL {
        let url = (directory ?? dir).appendingPathComponent(name)
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent).sorted() }

    func testMiniWithOriginalIsDeletable() throws {
        try make("Wimm_A.m4a")
        let mini = try make("Wimm_A_mini.m4a")
        let plan = DerivedAudioCleanupPlanner.plan(candidates: [mini])
        XCTAssertEqual(names(plan.deletable), ["Wimm_A_mini.m4a"])
        XCTAssertEqual(plan.orphans, [])
    }

    func testOriginalWithAnotherAudioExtensionCounts() throws {
        try make("Memo_B.mp3")
        let mini = try make("Memo_B_mini.m4a")
        XCTAssertEqual(names(DerivedAudioCleanupPlanner.plan(candidates: [mini]).deletable), ["Memo_B_mini.m4a"])
    }

    func testMiniWithoutOriginalIsOrphanEvenWithSidecarTextAndImage() throws {
        try make("Wimm_C.meta.json")
        try make("Wimm_C.txt")
        try make("Wimm_C.heic")
        try make("Wimm_C_screen1.heic")
        let mini = try make("Wimm_C_mini.m4a")
        let plan = DerivedAudioCleanupPlanner.plan(candidates: [mini])
        XCTAssertEqual(plan.deletable, [])
        XCTAssertEqual(names(plan.orphans), ["Wimm_C_mini.m4a"])
    }

    func testAnotherDerivedTierIsNotAnOriginal() throws {
        try make("Wimm_D_micro.m4a")
        let mini = try make("Wimm_D_mini.m4a")
        let cascade = try make("Wimm_D_micro_mini.m4a")
        let plan = DerivedAudioCleanupPlanner.plan(candidates: [mini, cascade])
        XCTAssertEqual(plan.deletable, [])
        XCTAssertEqual(names(plan.orphans), ["Wimm_D_micro_mini.m4a", "Wimm_D_mini.m4a"])
    }

    func testCascadeWithOriginalIsDeletable() throws {
        try make("Wimm_E.m4a")
        let cascade = try make("Wimm_E_micro_mini.m4a")
        XCTAssertEqual(names(DerivedAudioCleanupPlanner.plan(candidates: [cascade]).deletable), ["Wimm_E_micro_mini.m4a"])
    }

    func testZeroByteOriginalDoesNotCount() throws {
        try make("Wimm_F.m4a", bytes: 0)
        let mini = try make("Wimm_F_mini.m4a")
        XCTAssertEqual(names(DerivedAudioCleanupPlanner.plan(candidates: [mini]).orphans), ["Wimm_F_mini.m4a"])
    }

    func testOriginalMustBeInTheSameDirectory() throws {
        let trash = dir.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try make("Wimm_G.m4a")
        let trashedMini = try make("Wimm_G_mini.m4a", in: trash)
        XCTAssertEqual(names(DerivedAudioCleanupPlanner.plan(candidates: [trashedMini]).orphans), ["Wimm_G_mini.m4a"])
    }

    func testCandidateSelection() {
        func candidate(_ name: String, mini: Bool) -> Bool {
            DerivedAudioCleanupPlanner.isCandidate(URL(fileURLWithPath: "/x/" + name), includeLegacyMini: mini)
        }
        XCTAssertTrue(candidate("A_micro_mini.m4a", mini: false))
        XCTAssertFalse(candidate("A_mini.m4a", mini: false))
        XCTAssertTrue(candidate("A_mini.m4a", mini: true))
        XCTAssertFalse(candidate("A_micro.m4a", mini: true))
        XCTAssertFalse(candidate("A.m4a", mini: true))
        XCTAssertFalse(candidate("A_mini.txt", mini: true))
    }
}
