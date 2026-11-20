import AppKit
import SwiftUI

/// A receipt for a completed disk save, also visible when the HUD is hidden or tiny.
/// It also carries one standing status line (Алёна's phase): a receipt covers the
/// status for its few seconds, then the status comes back.
@MainActor
final class StudioSaveConfirmation {
    struct Line: Equatable {
        var message: String
        var systemImage: String
        /// Buttons beside the message; only then does the banner take clicks.
        var actions: [Action] = []
    }

    struct Action: Equatable {
        var title: String
        var isPrimary = false
        var run: @MainActor () -> Void

        static func == (a: Action, b: Action) -> Bool { a.title == b.title && a.isPrimary == b.isPrimary }
    }

    private var panel: NSPanel?
    private var hosting: NSHostingController<LineView>?
    private var dismissal: Task<Void, Never>?
    private var receipt: Line?
    private var status: Line?

    /// Drops the receipt. A standing status stays.
    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        receipt = nil
        render()
    }

    func show(count: Int, duration: Duration = .seconds(3)) {
        show(message: count == 1 ? "Сохранено" : "Сохранено заметок: \(count)", duration: duration)
    }

    /// Any short status worth seeing with the HUD hidden; a new one replaces the old.
    func show(message: String, systemImage: String = "checkmark.circle.fill", duration: Duration = .seconds(3)) {
        dismissal?.cancel()
        receipt = Line(message: message, systemImage: systemImage)
        render()
        if let panel {
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Shown until replaced or cleared with nil; it has no timer of its own.
    func setStatus(_ line: Line?) {
        guard status != line else { return }
        status = line
        if receipt == nil { render() }
    }

    private func render() {
        guard let line = receipt ?? status else {
            hosting = nil
            panel?.contentViewController = nil
            panel?.orderOut(nil)
            panel?.close()
            panel = nil
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        let hosting: NSHostingController<LineView>
        if let current = self.hosting {
            // Same view in place: a status that changes with speech must not blink.
            current.rootView = LineView(line: line)
            hosting = current
        } else {
            hosting = NSHostingController(rootView: LineView(line: line))
            hosting.sizingOptions = []
            panel.contentViewController = hosting
            self.hosting = hosting
        }
        panel.ignoresMouseEvents = line.actions.isEmpty
        let size = hosting.sizeThatFits(in: NSSize(width: line.actions.isEmpty ? 600 : 760, height: 160))
        // The screen is chosen when the banner appears; an update never moves it to another one.
        let screen = (panel.isVisible ? panel.screen : nil)
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            panel.setFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.minY + 60,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }

    struct LineView: View {
        let line: Line

        var body: some View {
            HStack(spacing: 14) {
                Label(line.message, systemImage: line.systemImage)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(line.actions, id: \.title) { action in
                    if action.isPrimary {
                        Button(action.title) { action.run() }.buttonStyle(.borderedProminent)
                    } else {
                        Button(action.title) { action.run() }
                    }
                }
            }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.identifier = NSUserInterfaceItemIdentifier("studio.saveConfirmation")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        return panel
    }
}
