import XCTest
@testable import WimmDomain

final class SessionRestartPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFirstSessionEndRestarts() {
        var policy = SessionRestartPolicy()

        XCTAssertEqual(policy.registerSessionEnd(at: start), .restart)
        XCTAssertEqual(policy.consecutiveRapidRestarts, 0)
    }

    func testDefaultsGiveUpAfterFiveConsecutiveRapidRestarts() {
        var policy = SessionRestartPolicy()

        for offset in [0.0, 0.1, 0.2, 0.3, 0.4] {
            XCTAssertEqual(
                policy.registerSessionEnd(at: start.addingTimeInterval(offset)),
                .restart
            )
        }
        XCTAssertEqual(
            policy.registerSessionEnd(at: start.addingTimeInterval(0.5)),
            .giveUp
        )
        XCTAssertEqual(policy.consecutiveRapidRestarts, 5)
    }

    func testGivesUpAtConfiguredRapidRestartThreshold() {
        var policy = SessionRestartPolicy(
            rapidRestartInterval: 1,
            maximumConsecutiveRapidRestarts: 2
        )

        XCTAssertEqual(policy.registerSessionEnd(at: start), .restart)
        XCTAssertEqual(policy.registerSessionEnd(at: start.addingTimeInterval(0.2)), .restart)
        XCTAssertEqual(policy.registerSessionEnd(at: start.addingTimeInterval(0.4)), .giveUp)
        XCTAssertEqual(policy.consecutiveRapidRestarts, 2)
    }

    func testEndAtIntervalBoundaryIsNotRapid() {
        var policy = SessionRestartPolicy(
            rapidRestartInterval: 1,
            maximumConsecutiveRapidRestarts: 2
        )

        _ = policy.registerSessionEnd(at: start)
        _ = policy.registerSessionEnd(at: start.addingTimeInterval(0.2))

        XCTAssertEqual(policy.registerSessionEnd(at: start.addingTimeInterval(1.2)), .restart)
        XCTAssertEqual(policy.consecutiveRapidRestarts, 0)
    }

    func testResetStartsANewSequence() {
        var policy = SessionRestartPolicy(
            rapidRestartInterval: 1,
            maximumConsecutiveRapidRestarts: 1
        )
        _ = policy.registerSessionEnd(at: start)
        XCTAssertEqual(
            policy.registerSessionEnd(at: start.addingTimeInterval(0.2)),
            .giveUp
        )

        policy.reset()

        XCTAssertEqual(
            policy.registerSessionEnd(at: start.addingTimeInterval(0.3)),
            .restart
        )
        XCTAssertEqual(policy.consecutiveRapidRestarts, 0)
    }
}
