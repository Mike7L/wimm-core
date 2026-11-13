import AppKit
import SwiftUI

/// Joins the HUD in full-screen Spaces while allowing ordinary text editing.
private final class StudioNotePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StudioNotePresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var entryID: UUID?
    private var isEditing = false

    func owns(_ candidate: NSWindow) -> Bool { window === candidate }

    func show(_ entry: StudioLibraryNote, onSave: @escaping (URL) -> Void,
              onOpenURL: @escaping (URL) -> Bool) {
        if isEditing || entryID == entry.id {
            bringForward()
            return
        }
        let window = window ?? makeWindow()
        entryID = entry.id
        window.title = entry.studioTitle
        window.contentViewController = NSHostingController(rootView: StudioNotePreview(
            entry: entry, onSelectBlock: nil, onSave: onSave,
            onClose: { [weak self] in self?.window?.performClose(nil) },
            onEditingChange: { [weak self] in self?.isEditing = $0 }
        ).id(entry.id).environment(\.openURL, OpenURLAction { url in
            onOpenURL(url) ? .handled : .systemAction
        }))
        bringForward()
    }

    private func bringForward() {
        // Activating Studio here can switch away from the user's full-screen app.
        // A nonactivating panel takes keyboard focus in the current Space instead.
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = StudioNotePanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 720),
                                     styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 520)
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isEditing }

    func windowWillClose(_ notification: Notification) {
        // Release the note, PDF page and player when its window closes.
        window?.contentViewController = nil
        entryID = nil
        isEditing = false
    }
}
