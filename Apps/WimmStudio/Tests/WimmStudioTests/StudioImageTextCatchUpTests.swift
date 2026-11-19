import XCTest
import WimmDomain
import WimmInfrastructure
@testable import WimmStudio

final class StudioImageTextCatchUpTests: XCTestCase {
    private let shot = URL(fileURLWithPath: "/tmp/Wimm_2026-11-16_16-00-19_507D763F.heic")

    func testFreshScreenshotNeedsText() {
        XCTAssertTrue(StudioImageTextCatchUp.needsText(
            file: shot, meta: ["title": "Screenshot", "origin": ["source": "studio-screenshot"]]))
        XCTAssertTrue(StudioImageTextCatchUp.needsText(
            file: URL(fileURLWithPath: "/tmp/Wimm_2026-11-16_16-00-19_507D763F.PNG"), meta: [:]))
    }

    func testReadPictureIsDoneEvenWithoutText() {
        XCTAssertFalse(StudioImageTextCatchUp.needsText(file: shot, meta: ["ocr": ["text": ""]]))
        XCTAssertFalse(StudioImageTextCatchUp.needsText(file: shot, meta: ["ocr": ["text": "Меню"]]))
    }

    func testPictureWithTextFromElsewhereIsDone() {
        XCTAssertFalse(StudioImageTextCatchUp.needsText(file: shot, meta: ["transcription": "Текст с iPhone"]))
        XCTAssertFalse(StudioImageTextCatchUp.needsText(file: shot, meta: ["transcription": ["transcript": "Текст"]]))
        XCTAssertFalse(StudioImageTextCatchUp.needsText(file: shot, meta: ["document": ["text": "Текст"]]))
        XCTAssertTrue(StudioImageTextCatchUp.needsText(file: shot, meta: ["transcription": ["transcript": " "]]))
    }

    func testOtherMediaIsSkipped() {
        for name in ["Wimm_2026-11-16_16-00-19_507D763F.m4a", "note.txt", "scan.pdf"] {
            XCTAssertFalse(StudioImageTextCatchUp.needsText(file: URL(fileURLWithPath: "/tmp/\(name)"), meta: [:]), name)
        }
    }
}
