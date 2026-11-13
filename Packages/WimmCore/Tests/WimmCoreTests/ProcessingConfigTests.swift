import XCTest
@testable import WimmInfrastructure

final class ProcessingConfigTests: XCTestCase {
    private var originalSharedValue: Any?
    private var originalStandardValue: Any?

    override func setUp() {
        super.setUp()
        originalSharedValue = SharedUserDefaults.store.object(forKey: DefaultsKey.processingNoteCardEnabled)
        originalStandardValue = UserDefaults.standard.object(forKey: DefaultsKey.processingNoteCardEnabled)
        SharedUserDefaults.store.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
    }

    override func tearDown() {
        if let originalSharedValue {
            SharedUserDefaults.store.set(originalSharedValue, forKey: DefaultsKey.processingNoteCardEnabled)
        } else {
            SharedUserDefaults.store.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
        }
        if let originalStandardValue {
            UserDefaults.standard.set(originalStandardValue, forKey: DefaultsKey.processingNoteCardEnabled)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.processingNoteCardEnabled)
        }
        super.tearDown()
    }

    func testDisabledByDefault() {
        XCTAssertFalse(ProcessingCfg.noteCardEnabled, "Analysis/NoteCard processing must be disabled by default")
        XCTAssertFalse(ProcessingCfg.analysisEnabled, "analysisEnabled alias must also be false by default")
    }

    func testTogglingNoteCardEnabled() {
        ProcessingCfg.noteCardEnabled = true
        XCTAssertTrue(ProcessingCfg.noteCardEnabled)
        XCTAssertTrue(ProcessingCfg.analysisEnabled)
        XCTAssertEqual(SharedUserDefaults.store.bool(forKey: DefaultsKey.processingNoteCardEnabled), true)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: DefaultsKey.processingNoteCardEnabled), true)

        ProcessingCfg.noteCardEnabled = false
        XCTAssertFalse(ProcessingCfg.noteCardEnabled)
        XCTAssertFalse(ProcessingCfg.analysisEnabled)
        XCTAssertEqual(SharedUserDefaults.store.bool(forKey: DefaultsKey.processingNoteCardEnabled), false)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: DefaultsKey.processingNoteCardEnabled), false)
    }

    func testTogglingAnalysisEnabledAlias() {
        ProcessingCfg.analysisEnabled = true
        XCTAssertTrue(ProcessingCfg.noteCardEnabled)
        XCTAssertTrue(ProcessingCfg.analysisEnabled)

        ProcessingCfg.analysisEnabled = false
        XCTAssertFalse(ProcessingCfg.noteCardEnabled)
        XCTAssertFalse(ProcessingCfg.analysisEnabled)
    }

    func testReadsExistingStandardDefaultIfSharedNotSet() {
        UserDefaults.standard.set(true, forKey: DefaultsKey.processingNoteCardEnabled)
        XCTAssertTrue(ProcessingCfg.noteCardEnabled)

        UserDefaults.standard.set(false, forKey: DefaultsKey.processingNoteCardEnabled)
        XCTAssertFalse(ProcessingCfg.noteCardEnabled)
    }
}
