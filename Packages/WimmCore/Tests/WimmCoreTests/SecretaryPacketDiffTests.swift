import Foundation
import WimmDomain
import XCTest
@testable import WimmInfrastructure
@testable import WimmSecretary

final class SecretaryPacketDiffTests: XCTestCase {
    func testUnifiedDiffShowsOnlyTheChangedLines() {
        let diff = SecretaryPacket.unifiedDiff("a\nb\nc\n", "a\nb\nnew\nc\n", name: "me.md")
        XCTAssertEqual(diff, "--- a/me.md\n+++ b/me.md\n@@ -1,4 +1,5 @@\n a\n b\n+new\n c\n \n")
        XCTAssertEqual(SecretaryPacket.unifiedDiff("same", "same", name: "me.md"), "")
    }
}
