import AppKit
import Observation

/// Screen edge an island HUD is attached to.
enum HUDIslandEdge: String, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }

    var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        }
    }

    var isHorizontal: Bool { self == .top || self == .bottom }
}

/// Pure frame math for the island HUD (AppKit coordinates, y grows upward).
/// The island is flush with one edge of `bounds` (a screen's visible frame) and
/// keeps its position along that edge as a 0...1 fraction of the free span, so
/// collapsing and expanding never move its anchor.
enum HUDIslandGeometry {
    static let thickness: CGFloat = 18
    static let length: CGFloat = 56

    static func collapsedSize(for edge: HUDIslandEdge) -> NSSize {
        edge.isHorizontal
            ? NSSize(width: length, height: thickness)
            : NSSize(width: thickness, height: length)
    }

    /// The edge whose distance to the frame is smallest.
    static func nearestEdge(of frame: NSRect, in bounds: NSRect) -> HUDIslandEdge {
        let distances: [(HUDIslandEdge, CGFloat)] = [
            (.top, abs(bounds.maxY - frame.maxY)),
            (.bottom, abs(frame.minY - bounds.minY)),
            (.left, abs(frame.minX - bounds.minX)),
            (.right, abs(bounds.maxX - frame.maxX)),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// Where the frame's center sits along `edge`, 0...1.
    static func along(of frame: NSRect, edge: HUDIslandEdge, in bounds: NSRect) -> CGFloat {
        let (center, lo, span) = edge.isHorizontal
            ? (frame.midX, bounds.minX, bounds.width)
            : (frame.midY, bounds.minY, bounds.height)
        guard span > 0 else { return 0.5 }
        return min(1, max(0, (center - lo) / span))
    }

    static func frame(edge: HUDIslandEdge, along: CGFloat, size: NSSize, in bounds: NSRect) -> NSRect {
        let w = min(size.width, bounds.width)
        let h = min(size.height, bounds.height)
        var rect = NSRect(x: 0, y: 0, width: w, height: h)
        if edge.isHorizontal {
            rect.origin.x = bounds.minX + along * bounds.width - w / 2
            rect.origin.y = edge == .top ? bounds.maxY - h : bounds.minY
        } else {
            rect.origin.y = bounds.minY + along * bounds.height - h / 2
            rect.origin.x = edge == .left ? bounds.minX : bounds.maxX - w
        }
        rect.origin.x = min(max(rect.origin.x, bounds.minX), bounds.maxX - w)
        rect.origin.y = min(max(rect.origin.y, bounds.minY), bounds.maxY - h)
        return rect
    }

    static func collapsedFrame(edge: HUDIslandEdge, along: CGFloat, in bounds: NSRect) -> NSRect {
        frame(edge: edge, along: along, size: collapsedSize(for: edge), in: bounds)
    }
}

/// UI-facing island state shared by the panel and the SwiftUI view.
@MainActor
@Observable
final class HUDIslandModel {
    var isEnabled = false
    var isExpanded = false
    var edge: HUDIslandEdge = .top

    /// Set by the panel: expands or collapses the window.
    @ObservationIgnored var onToggle: () -> Void = {}

    /// Set by the HUD view: toggles recording when the collapsed pill is clicked.
    @ObservationIgnored var onTapPill: (() -> Void)?

    /// The view shows the compact pill only while the island is collapsed.
    var showsPill: Bool { isEnabled && !isExpanded }
}
