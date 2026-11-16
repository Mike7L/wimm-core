import AppKit
import QuartzCore
import SwiftUI

/// Borderless, non-activating floating panel with top-edge and right-corner manual
/// resizing. The frame belongs 100% to the user: there are no discrete modes
/// (nano/mini/full) and no state-driven height jumps.
final class ResponsiveHUDPanel: NSPanel {
    static let minSize = NSSize(width: 76, height: 32)
    static let maxSize = NSSize(width: 900, height: 1200)
    static let defaultFrame = NSRect(x: 80, y: 120, width: 360, height: 220)
    static let resizeCornerSize: CGFloat = 18
    enum ResizeHandle { case top, topRight, bottomRight }
    private var resizeHandle: ResizeHandle?
    private static let frameDefaultsKey = "WimmStudio.hudFrame"

    private var isResizingCorner = false
    private var startFrame: NSRect?
    private var startMouse: NSPoint?
    private var trackingArea: NSTrackingArea?
    private var showingResizeCursor = false

    /// Island mode: the panel is a compact pill attached to a screen edge and
    /// expands on click. State is shared with the SwiftUI view.
    let island: HUDIslandModel
    private var expandedSize = NSSize(width: 360, height: 220)
    private var along: CGFloat = 0.5
    /// Hover opens the island; it closes again on exit unless a click pinned it.
    private var isPinnedOpen = false
    static let hoverExpandDelay: TimeInterval = 0.12
    static let hoverCollapseDelay: TimeInterval = 0.18
    static let expandDuration: TimeInterval = 0.20
    static let collapseDuration: TimeInterval = 0.16
    private var hoverWork: DispatchWorkItem?
    private var snapWork: DispatchWorkItem?
    private var morphSettleWork: DispatchWorkItem?
    private var collapseFrameWork: DispatchWorkItem?
    private var morphGeneration: UInt64 = 0
    private var ignoreMovesUntil = Date.distantPast
    private static let collapsedAlpha: CGFloat = 0.8
    /// Buttons swallow mouse-down, so the window server never starts a move from
    /// them; in island mode a drag that starts on a control moves the panel by hand.
    private var dragStartMouse: NSPoint?
    private var isManualDragging = false
    private static let manualDragThreshold: CGFloat = 4
    private var mouseDownOrigin: NSPoint?
    private var mouseDownSize: NSSize?
    private static let islandKey = "WimmStudio.hudIsland"
    private static let islandEdgeKey = "WimmStudio.hudIslandEdge"
    private static let islandAlongKey = "WimmStudio.hudIslandAlong"
    private static let islandSizeKey = "WimmStudio.hudIslandExpandedSize"

    @MainActor
    init<Content: View>(rootView: Content, island: HUDIslandModel? = nil) {
        let island = island ?? HUDIslandModel()
        self.island = island
        let initial = Self.restoredFrame() ?? Self.defaultFrame
        super.init(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = false
        initialFirstResponder = nil
        contentMinSize = Self.minSize
        contentMaxSize = Self.maxSize

        let hosting = NSHostingController(rootView: rootView)
        // Never let SwiftUI push its ideal size onto the window during a drag.
        hosting.sizingOptions = []
        hosting.view.focusRingType = .none
        contentViewController = hosting
        setFrame(initial, display: true)
        installTrackingArea()
        island.onToggle = { [weak self] in self?.toggleIsland() }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleSnapAfterMove() } }
        restoreIsland()
    }

    // MARK: - Island

    private var islandBounds: NSRect {
        (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func setIslandEnabled(_ enabled: Bool, animated: Bool = true) {
        guard enabled != island.isEnabled else { return }
        cancelMorphWork()
        island.isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.islandKey)
        if enabled {
            if frame.height > ResponsiveHUDLayout.barHeight + 20 { expandedSize = frame.size }
            island.edge = HUDIslandGeometry.nearestEdge(of: frame, in: islandBounds)
            along = HUDIslandGeometry.along(of: frame, edge: island.edge, in: islandBounds)
            contentMinSize = NSSize(width: 24, height: 24)
            island.isExpanded = false
            island.isMorphing = false
            island.morphFraction = 0
            applyIslandFrame(animated: animated)
        } else {
            contentMinSize = Self.minSize
            alphaValue = 1
            hasShadow = true
            island.isExpanded = false
            island.isMorphing = false
            island.morphFraction = 0
            super.setFrame(Self.restoredFrame() ?? Self.defaultFrame, display: true)
        }
        persistIsland()
    }

    func setIslandEdge(_ edge: HUDIslandEdge, animated: Bool = true) {
        guard island.isEnabled else { return }
        cancelMorphWork()
        island.edge = edge
        along = 0.5
        applyIslandFrame(animated: animated)
        persistIsland()
    }

    func toggleIsland(animated: Bool = true) {
        guard island.isEnabled else { return }
        setIslandExpanded(!island.isExpanded, animated: animated)
    }

    func setIslandExpanded(_ expanded: Bool, animated: Bool = true) {
        guard island.isEnabled, island.isExpanded != expanded else { return }
        let wasMorphing = island.isMorphing
        if island.isExpanded && !wasMorphing { expandedSize = frame.size }
        mouseDownOrigin = nil  // the click that caused this is handled
        cancelMorphWork()

        let geom = islandGeometry(in: islandBounds)
        syncIslandMetrics(collapsed: geom.collapsed, expanded: geom.expanded, container: geom.container)

        guard animated, isVisible else {
            island.isExpanded = expanded
            island.isMorphing = false
            island.morphFraction = expanded ? 1 : 0
            alphaValue = expanded ? 1 : Self.collapsedAlpha
            hasShadow = true
            ignoreMovesUntil = Date().addingTimeInterval(0.3)
            super.setFrame(expanded ? geom.expanded : geom.collapsed, display: true)
            snapWork?.cancel()
            persistIsland()
            return
        }

        ignoreMovesUntil = Date().addingTimeInterval(0.4)
        snapWork?.cancel()
        // Avoid per-frame WindowServer alpha-shadow recomputation during the morph.
        hasShadow = false

        if expanded {
            let alreadyInContainer = wasMorphing && frame.size == geom.container.size
            island.isExpanded = true
            island.isMorphing = true
            alphaValue = 1
            morphGeneration &+= 1
            let generation = morphGeneration
            if !alreadyInContainer {
                island.morphFraction = 0
                super.setFrame(geom.container, display: true)
                contentView?.layoutSubtreeIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.morphGeneration == generation,
                          self.island.isEnabled, self.island.isExpanded else { return }
                    self.animateMorph(to: 1, duration: Self.expandDuration, spring: true)
                }
            } else {
                animateMorph(to: 1, duration: Self.expandDuration, spring: true)
            }
            let settle = DispatchWorkItem { [weak self] in
                guard let self, self.morphGeneration == generation,
                      self.island.isEnabled, self.island.isExpanded else { return }
                self.island.isMorphing = false
                if self.frame != geom.expanded {
                    self.ignoreMovesUntil = Date().addingTimeInterval(0.25)
                    self.setWindowFrameDirectly(geom.expanded)
                }
                self.hasShadow = true
                self.invalidateShadow()
            }
            morphSettleWork = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.expandDuration + 0.05, execute: settle)
        } else {
            morphGeneration &+= 1
            let generation = morphGeneration
            if frame.size != geom.container.size {
                super.setFrame(geom.container, display: true)
                contentView?.layoutSubtreeIfNeeded()
            }
            island.isExpanded = false
            island.isMorphing = true
            animateMorph(to: 0, duration: Self.collapseDuration, spring: false)
            let collapse = DispatchWorkItem { [weak self] in
                guard let self, self.morphGeneration == generation,
                      self.island.isEnabled, !self.island.isExpanded else { return }
                self.island.isMorphing = false
                self.alphaValue = Self.collapsedAlpha
                self.ignoreMovesUntil = Date().addingTimeInterval(0.25)
                self.setWindowFrameDirectly(geom.collapsed)
                self.hasShadow = true
                self.invalidateShadow()
            }
            collapseFrameWork = collapse
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDuration + 0.03, execute: collapse)
        }
        persistIsland()
    }

    private func setWindowFrameDirectly(_ rect: NSRect) {
        super.setFrame(rect, display: true)
    }

    private func cancelMorphWork() {
        collapseFrameWork?.cancel()
        collapseFrameWork = nil
        morphSettleWork?.cancel()
        morphSettleWork = nil
    }

    private func animateMorph(to target: CGFloat, duration: TimeInterval, spring: Bool) {
        let animation: Animation = spring
            ? .spring(duration: duration, bounce: 0.12)
            : .easeOut(duration: duration)
        withAnimation(animation) {
            island.morphFraction = target
        }
    }

    private func islandGeometry(in bounds: NSRect) -> (collapsed: NSRect, expanded: NSRect, container: NSRect) {
        let collapsed = HUDIslandGeometry.collapsedFrame(edge: island.edge, along: along, in: bounds)
        let expanded = HUDIslandGeometry.frame(edge: island.edge, along: along, size: expandedSize, in: bounds)
        return (collapsed, expanded, expanded.union(collapsed))
    }

    private func syncIslandMetrics(collapsed: NSRect, expanded: NSRect, container: NSRect) {
        island.expandedSize = expanded.size
        island.collapsedSize = collapsed.size
        island.containerSize = container.size
        island.collapsedOrigin = NSPoint(x: collapsed.minX - container.minX, y: container.maxY - collapsed.maxY)
        island.expandedOrigin = NSPoint(x: expanded.minX - container.minX, y: container.maxY - expanded.maxY)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // macOS keeps borderless windows off the menu bar and screen edge; the
        // island has to reach the very edge.
        island.isEnabled ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    /// The window server runs window drags itself and may swallow the mouse-up,
    /// so a drag is detected by the frame settling.
    private func scheduleSnapAfterMove() {
        guard island.isEnabled, Date() > ignoreMovesUntil else { return }
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.island.isEnabled else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 { self.scheduleSnapAfterMove(); return }
            self.snapIsland()
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func islandPointerEntered() {
        guard island.isEnabled, !island.isExpanded else { return }
        isPinnedOpen = false
        setIslandExpanded(true)
    }

    func islandPointerExited() {
        guard island.isEnabled, island.isExpanded, !isPinnedOpen else { return }
        if NSEvent.pressedMouseButtons != 0 {
            scheduleHoverCollapse()
            return
        }
        if isVisible, frame.contains(NSEvent.mouseLocation) { return }
        setIslandExpanded(false)
    }

    private func scheduleHoverCollapse() {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.islandPointerExited() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverCollapseDelay, execute: work)
    }

    private func applyIslandFrame(animated: Bool) {
        ignoreMovesUntil = Date().addingTimeInterval(0.35)
        alphaValue = island.isEnabled && !island.isExpanded ? Self.collapsedAlpha : 1
        let geom = islandGeometry(in: islandBounds)
        syncIslandMetrics(collapsed: geom.collapsed, expanded: geom.expanded, container: geom.container)
        island.isMorphing = false
        island.morphFraction = island.isExpanded ? 1 : 0
        let target = island.isExpanded ? geom.expanded : geom.collapsed
        if animated, isVisible {
            snapWork?.cancel()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // animator() returns an NSProxy; dispatch through NSWindow/dynamic ObjC so
                // Release optimization cannot devirtualize/inline ResponsiveHUDPanel.setFrame onto the proxy.
                (self as NSWindow).animator().setFrame(target, display: true)
            }
        } else {
            super.setFrame(target, display: true)
        }
    }

    /// After a drag or resize: attach to the nearest edge, keep the position along it.
    private func snapIsland() {
        guard island.isEnabled else { return }
        if island.isExpanded { expandedSize = frame.size }
        island.edge = HUDIslandGeometry.nearestEdge(of: frame, in: islandBounds)
        along = HUDIslandGeometry.along(of: frame, edge: island.edge, in: islandBounds)
        applyIslandFrame(animated: true)
        persistIsland()
    }

    private func persistIsland() {
        let d = UserDefaults.standard
        d.set(island.edge.rawValue, forKey: Self.islandEdgeKey)
        d.set(Double(along), forKey: Self.islandAlongKey)
        d.set(NSStringFromSize(expandedSize), forKey: Self.islandSizeKey)
    }

    private func restoreIsland() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Self.islandSizeKey) {
            let size = NSSizeFromString(raw)
            if size.width >= Self.minSize.width, size.height >= Self.minSize.height { expandedSize = size }
        }
        if let raw = d.string(forKey: Self.islandEdgeKey), let e = HUDIslandEdge(rawValue: raw) { island.edge = e }
        if d.object(forKey: Self.islandAlongKey) != nil { along = CGFloat(d.double(forKey: Self.islandAlongKey)) }
        if d.bool(forKey: Self.islandKey) {
            island.isEnabled = true
            contentMinSize = NSSize(width: 24, height: 24)
            applyIslandFrame(animated: false)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Prevent AppKit from focusing HUD buttons and drawing a selection/focus ring.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        guard responder == nil || responder === self || responder === contentView else {
            return super.makeFirstResponder(nil)
        }
        return super.makeFirstResponder(responder)
    }

    @objc dynamic override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        if !island.isEnabled { Self.persistFrame(frameRect) }
    }

    // MARK: - Manual resize without window-move jitter

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            hoverWork?.cancel()
            dragStartMouse = NSEvent.mouseLocation
            isManualDragging = false
            if island.isExpanded, !isPointInControlBar(event.locationInWindow) {
                isPinnedOpen = true
            }
            mouseDownOrigin = frame.origin
            mouseDownSize = frame.size
            let handle = resizeHandle(at: event.locationInWindow)
            let overCorner = handle != nil
            updateMovable(overCorner: overCorner)
            if overCorner {
                isResizingCorner = true
                resizeHandle = handle
                startFrame = frame
                startMouse = NSEvent.mouseLocation
                return
            }
        case .rightMouseDown:
            if island.showsPill {
                hoverWork?.cancel()
                isPinnedOpen = true
                setIslandExpanded(true)
                return
            }
            if island.isExpanded {
                isPinnedOpen = true
            }
        case .leftMouseDragged:
            if island.isEnabled, !isResizingCorner, let start = dragStartMouse, let origin = mouseDownOrigin {
                let mouse = NSEvent.mouseLocation
                let dx = mouse.x - start.x, dy = mouse.y - start.y
                if isManualDragging || hypot(dx, dy) > Self.manualDragThreshold {
                    isManualDragging = true
                    setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
                    return
                }
            }
            if isResizingCorner {
                applyDrag(to: NSEvent.mouseLocation)
                return
            }
        case .leftMouseUp:
            if isManualDragging {
                isManualDragging = false
                dragStartMouse = nil
                // Release far outside so the control under the pointer cancels its click.
                if let outside = NSEvent.mouseEvent(
                    with: .leftMouseUp, location: NSPoint(x: -5000, y: -5000), modifierFlags: [],
                    timestamp: event.timestamp, windowNumber: windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 0
                ) { super.sendEvent(outside) }
                if island.isEnabled { snapIsland() }
                mouseDownOrigin = nil
                return
            }
            dragStartMouse = nil
            if isResizingCorner {
                applyDrag(to: NSEvent.mouseLocation)
                isResizingCorner = false
                resizeHandle = nil
                startFrame = nil
                startMouse = nil
                if island.isEnabled { snapIsland() }
                updateMovable(overCorner: isInResizeCorner(at: event.locationInWindow))
                return
            }
        case .mouseMoved:
            updateCursor(at: event.locationInWindow)
        default:
            break
        }
        super.sendEvent(event)
        if event.type == .leftMouseUp, island.isEnabled { finishIslandGesture() }
    }

    /// A press that moved nothing is a click (toggles recording on the pill, or expands if unweighted); otherwise snap to an edge.
    private func finishIslandGesture() {
        defer { mouseDownOrigin = nil; mouseDownSize = nil }
        guard let origin = mouseDownOrigin, let size = mouseDownSize else { return }
        if island.showsPill {
            if origin == frame.origin {
                if let onTapPill = island.onTapPill {
                    onTapPill()
                } else {
                    isPinnedOpen = true
                    setIslandExpanded(true)
                }
            } else {
                snapIsland()
            }
        } else if origin != frame.origin || size != frame.size {
            snapIsland()
        }
    }

    private func isPointInControlBar(_ point: NSPoint) -> Bool {
        let barHeight = min(frame.height, ResponsiveHUDLayout.barHeight)
        if island.isEnabled && island.edge == .top {
            return point.y >= frame.height - barHeight
        }
        return point.y <= barHeight
    }

    func installTrackingArea() {
        guard let contentView else { return }
        if let trackingArea { contentView.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        contentView.addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if !updateCursor(at: event.locationInWindow) {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: event.locationInWindow)
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        hoverWork?.cancel()
        if island.isMorphing && !island.isExpanded {
            islandPointerEntered()
            return
        }
        guard island.showsPill else { return super.mouseEntered(with: event) }
        let work = DispatchWorkItem { [weak self] in self?.islandPointerEntered() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverExpandDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hoverWork?.cancel()
        if island.isExpanded && !isPinnedOpen {
            scheduleHoverCollapse()
        }
        resetCursor()
        updateMovable(overCorner: false)
        super.mouseExited(with: event)
    }

    private func updateMovable(overCorner: Bool) {
        let movable = !overCorner && !isResizingCorner
        if isMovableByWindowBackground != movable {
            isMovableByWindowBackground = movable
        }
    }

    @discardableResult
    private func updateCursor(at point: NSPoint) -> Bool {
        let handle = resizeHandle ?? resizeHandle(at: point)
        let active = handle != nil
        updateMovable(overCorner: active)
        if active {
            if #available(macOS 15.0, *) {
                switch handle {
                case .top: NSCursor.frameResize(position: .top, directions: .all).set()
                case .topRight: NSCursor.frameResize(position: .topRight, directions: .all).set()
                default: NSCursor.frameResize(position: .bottomRight, directions: .all).set()
                }
            } else {
                NSCursor.resizeLeftRight.set()
            }
            showingResizeCursor = true
            return true
        }
        resetCursor()
        return false
    }

    private func resetCursor() {
        guard showingResizeCursor else { return }
        NSCursor.arrow.set()
        showingResizeCursor = false
    }

    func isInResizeCorner(at point: NSPoint) -> Bool {
        resizeHandle(at: point) != nil
    }

    func resizeHandle(at point: NSPoint) -> ResizeHandle? {
        guard !island.showsPill, point.x >= 0, point.x <= frame.width,
              point.y >= 0, point.y <= frame.height else { return nil }
        let size = Self.resizeCornerSize
        let topAttached = island.isEnabled && island.edge == .top
        if point.x >= frame.width - size {
            if !topAttached && point.y >= frame.height - size { return .topRight }
            if point.y <= size { return .bottomRight }
        }
        if !topAttached && point.y >= frame.height - 6 { return .top }
        return nil
    }

    private func applyDrag(to mouse: NSPoint) {
        guard let startFrame, let startMouse, let resizeHandle else { return }
        let next = Self.resizedFrame(startFrame, delta: NSPoint(x: mouse.x - startMouse.x,
                                                               y: mouse.y - startMouse.y),
                                     handle: resizeHandle, bounds: islandBounds)
        if island.isEnabled {
            cancelMorphWork()
            island.isMorphing = false
            island.morphFraction = 1
            expandedSize = next.size
            island.expandedSize = next.size
            island.containerSize = next.size
            island.expandedOrigin = .zero
        }
        setFrame(next, display: true)
    }

    static func resizedFrame(_ start: NSRect, delta: NSPoint, handle: ResizeHandle, bounds: NSRect) -> NSRect {
        var next = start
        if handle != .top {
            let availableWidth = max(minSize.width, bounds.maxX - start.minX)
            next.size.width = min(max(start.width + delta.x, minSize.width), min(maxSize.width, availableWidth))
        }
        if handle == .bottomRight {
            let availableHeight = max(minSize.height, start.maxY - bounds.minY)
            next.size.height = min(max(start.height - delta.y, minSize.height), min(maxSize.height, availableHeight))
            next.origin.y = start.maxY - next.height
        } else {
            // Keep the lower edge anchored: this works even at the bottom of the screen.
            let availableHeight = max(minSize.height, bounds.maxY - start.minY)
            next.size.height = min(max(start.height + delta.y, minSize.height), min(maxSize.height, availableHeight))
        }
        return next
    }

    private static func restoredFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: frameDefaultsKey) else { return nil }
        let rect = NSRectFromString(str)
        guard rect.width >= minSize.width, rect.height >= minSize.height else { return nil }
        return rect
    }

    private static func persistFrame(_ rect: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(rect), forKey: frameDefaultsKey)
    }
}
