import XCTest
@testable import WimmStudio

@MainActor
final class StudioPanelsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "StudioPanelsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testFirstLaunchShowsDocumentAndTimelineUnlessTheOldSwitchHidTheTimeline() {
        XCTAssertEqual(StudioWindowModel(defaults: defaults()).visible, [.document, .timeline])
        let hidden = defaults()
        hidden.set(false, forKey: StudioWindowModel.legacyTimelineKey)
        XCTAssertEqual(StudioWindowModel(defaults: hidden).visible, [.document])
    }

    func testVisibilityAndWidthsSurviveARelaunchAndEveryPanelCanBeHidden() {
        let store = defaults()
        let model = StudioWindowModel(defaults: store)
        model.setVisible(.alyona, true)
        for panel in [StudioPanel.document, .timeline] { model.toggle(panel) }
        model.setWidth(410, for: .alyona)
        model.storeWidth(of: .alyona)

        let again = StudioWindowModel(defaults: store)
        XCTAssertEqual(again.shownPanels, [.alyona])
        XCTAssertEqual(again.width(of: .alyona), 410)

        again.setVisible(.alyona, false)
        XCTAssertTrue(StudioWindowModel(defaults: store).shownPanels.isEmpty)
    }

    func testWidthsAreClampedAndFlexiblePanelsHaveNone() {
        let model = StudioWindowModel(defaults: defaults())
        model.setWidth(10, for: .timeline)
        XCTAssertEqual(model.width(of: .timeline), StudioPanel.timeline.minWidth)
        model.setWidth(5_000, for: .notes)
        XCTAssertEqual(model.width(of: .notes), StudioPanel.maxFixedWidth)
        model.setWidth(700, for: .document)
        XCTAssertNil(model.width(of: .document))
        XCTAssertNil(model.width(of: .note))
    }

    func testShortcutsFollowWindowOrder() {
        XCTAssertEqual(StudioPanel.allCases.map(\.shortcut), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(StudioPanel.allCases, [.timeline, .notes, .note, .document, .alyona])
    }

    func testSeparatorsResizeTheFixedPanelFacingTheFlexibleOnes() {
        let all = StudioPanelLayout(shown: StudioPanel.allCases)
        XCTAssertEqual(all.resized(between: 0), .init(panel: .timeline, sign: 1))
        XCTAssertEqual(all.resized(between: 1), .init(panel: .notes, sign: 1))
        XCTAssertNil(all.resized(between: 2), "note | document: both flexible")
        XCTAssertEqual(all.resized(between: 3), .init(panel: .alyona, sign: -1))

        // No flexible panel shown: the last one fills, the others grow to the right.
        let fixed = StudioPanelLayout(shown: [.timeline, .notes, .alyona])
        XCTAssertTrue(fixed.fills(.alyona))
        XCTAssertFalse(fixed.fills(.notes))
        XCTAssertEqual(fixed.resized(between: 0), .init(panel: .timeline, sign: 1))
        XCTAssertEqual(fixed.resized(between: 1), .init(panel: .notes, sign: 1))
    }

    func testRevealingABlockBringsTheDocumentBack() {
        let model = StudioWindowModel(defaults: defaults())
        model.setVisible(.document, false)
        model.reveal(blockID: 42)
        XCTAssertTrue(model.isVisible(.document))
        XCTAssertEqual(model.revealBlockID, 42)
    }
}
