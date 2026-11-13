import XCTest
@testable import WimmStudio

final class HUDTailFollowTests: XCTestCase {
    func testScrollingUpStopsFollowing() {
        XCTAssertFalse(HUDTailFollow.next(current: true, previousOffsetY: 400, offsetY: 300, atEnd: false))
    }

    func testGrowingContentKeepsFollowing() {
        // New live text makes the content taller; the offset stays, so the
        // list is briefly not at the end but the user did nothing.
        let atEnd = HUDTailFollow.isAtEnd(offsetY: 400, viewportHeight: 200, contentHeight: 660)
        XCTAssertFalse(atEnd)
        XCTAssertTrue(HUDTailFollow.next(current: true, previousOffsetY: 400, offsetY: 400, atEnd: atEnd))
    }

    func testNewTextWhileScrolledUpStaysPut() {
        XCTAssertFalse(HUDTailFollow.next(current: false, previousOffsetY: 300, offsetY: 300, atEnd: false))
    }

    func testReachingTheEndResumesFollowing() {
        let atEnd = HUDTailFollow.isAtEnd(offsetY: 450, viewportHeight: 200, contentHeight: 660)
        XCTAssertTrue(atEnd)
        XCTAssertTrue(HUDTailFollow.next(current: false, previousOffsetY: 300, offsetY: 450, atEnd: atEnd))
    }
}
