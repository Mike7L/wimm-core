import Foundation
import Observation
import WimmInfrastructure

/// The panels of Studio's main window, left to right
/// (`docs/Studio_Panels_Plan_2026-11-21.md`). Any of them can be hidden.
enum StudioPanel: String, CaseIterable, Identifiable, Sendable {
    case timeline, notes, note, document, alyona

    var id: String { rawValue }

    var title: String {
        switch self {
        case .timeline: "Таймлайн"
        case .notes: "Заметки"
        case .note: "Заметка"
        case .document: "Документ"
        case .alyona: "Алёна"
        }
    }

    var systemImage: String {
        switch self {
        case .timeline: "calendar.day.timeline.left"
        case .notes: "list.bullet"
        case .note: "note.text"
        case .document: "doc.text"
        case .alyona: "bubble.left"
        }
    }

    /// ⌘1…⌘5, in window order.
    var shortcut: Character {
        Character(String((StudioPanel.allCases.firstIndex(of: self) ?? 0) + 1))
    }

    /// Nil for a panel that takes the room the fixed ones leave.
    var defaultWidth: CGFloat? {
        switch self {
        case .timeline: 280
        case .notes: 300
        case .alyona: 340
        case .note, .document: nil
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .timeline: 220
        case .notes: 260
        case .note: 360
        case .document: 420
        case .alyona: 300
        }
    }

    static let maxFixedWidth: CGFloat = 560
}

/// Which panels are shown, how wide the fixed ones are, and the requests that
/// cross panels (open a note, show a document block). Visibility and widths
/// survive relaunches.
@MainActor @Observable
final class StudioWindowModel {
    private(set) var visible: Set<StudioPanel>
    private(set) var widths: [StudioPanel: CGFloat]
    /// The note shown in the note sheet (the note panel replaces it in step 2).
    var openedNote: StudioLibraryNote?
    /// The note the timeline scrolls to; set after a yield so the same id twice still scrolls.
    private(set) var revealNoteID: UUID?
    /// A document block to scroll to; the document panel clears it once used.
    var revealBlockID: Int?
    /// Mirror of `PrivateMode.isEnabled`, which is not observable itself.
    private(set) var privateMode: Bool

    @ObservationIgnored private let defaults: UserDefaults

    static let visibleKey = "WimmStudio.panels.visible"
    /// The document window's old timeline switch: read once, when no panel set is stored yet.
    static let legacyTimelineKey = "WimmStudio.showsTimeline"
    static func widthKey(_ panel: StudioPanel) -> String { "WimmStudio.panels.width.\(panel.rawValue)" }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.visibleKey) {
            visible = Set(stored.compactMap(StudioPanel.init(rawValue:)))
        } else {
            var start: Set<StudioPanel> = [.document]
            if defaults.object(forKey: Self.legacyTimelineKey) as? Bool ?? true { start.insert(.timeline) }
            visible = start
        }
        var widths: [StudioPanel: CGFloat] = [:]
        for panel in StudioPanel.allCases where panel.defaultWidth != nil {
            if let value = defaults.object(forKey: Self.widthKey(panel)) as? Double {
                widths[panel] = Self.clamped(CGFloat(value), for: panel)
            }
        }
        self.widths = widths
        privateMode = PrivateMode.isEnabled
    }

    var shownPanels: [StudioPanel] { StudioPanel.allCases.filter(visible.contains) }

    func isVisible(_ panel: StudioPanel) -> Bool { visible.contains(panel) }

    func toggle(_ panel: StudioPanel) { setVisible(panel, !isVisible(panel)) }

    func setVisible(_ panel: StudioPanel, _ shown: Bool) {
        guard shown != isVisible(panel) else { return }
        if shown { visible.insert(panel) } else { visible.remove(panel) }
        defaults.set(StudioPanel.allCases.filter(visible.contains).map(\.rawValue), forKey: Self.visibleKey)
    }

    /// Nil for a flexible panel.
    func width(of panel: StudioPanel) -> CGFloat? {
        guard let fallback = panel.defaultWidth else { return nil }
        return widths[panel] ?? fallback
    }

    /// While dragging: the value changes, nothing is stored yet.
    func setWidth(_ width: CGFloat, for panel: StudioPanel) {
        guard panel.defaultWidth != nil else { return }
        widths[panel] = Self.clamped(width, for: panel)
    }

    func storeWidth(of panel: StudioPanel) {
        guard let width = widths[panel] else { return }
        defaults.set(Double(width), forKey: Self.widthKey(panel))
    }

    static func clamped(_ width: CGFloat, for panel: StudioPanel) -> CGFloat {
        min(max(width, panel.minWidth), max(panel.minWidth, StudioPanel.maxFixedWidth))
    }

    func open(_ note: StudioLibraryNote) {
        revealNoteID = nil
        Task { @MainActor in
            await Task.yield()
            revealNoteID = note.id
        }
        openedNote = note
    }

    /// Shows the document panel and scrolls it to `blockID`.
    func reveal(blockID: Int) {
        setVisible(.document, true)
        revealBlockID = blockID
    }

    func setPrivateMode(_ enabled: Bool) {
        PrivateMode.setStored(enabled)
        privateMode = PrivateMode.isEnabled
    }

    func refreshPrivateMode() { privateMode = PrivateMode.isEnabled }
}
