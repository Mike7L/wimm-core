import AppKit
import SwiftUI

/// A receipt for a completed disk save, also visible when the HUD is hidden or tiny.
@MainActor
final class StudioSaveConfirmation {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.contentViewController = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func show(count: Int, duration: Duration = .seconds(3)) {
        show(message: count == 1 ? "Сохранено" : "Сохранено заметок: \(count)", duration: duration)
    }

    /// Any short status worth seeing with the HUD hidden; a new one replaces the old.
    func show(message: String, systemImage: String = "checkmark.circle.fill", duration: Duration = .seconds(3)) {
        dismissal?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        let hosting = NSHostingController(rootView:
            Label(message, systemImage: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        )
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        let size = hosting.sizeThatFits(in: NSSize(width: 600, height: 100))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            panel.setFrame(NSRect(x: bounds.midX - size.width / 2, y: bounds.minY + 60,
                                  width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss()
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
