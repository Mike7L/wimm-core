import AppKit
import SwiftUI

/// Owns the evening window. Reopening the same evening brings the window
/// forward; a new evening (after 4 AM) gets a fresh model.
@MainActor
final class EveningPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var model: EveningModel?

    func owns(_ candidate: NSWindow) -> Bool { window === candidate }

    func show(recentNotes: RecentNotes, capture: CaptureSession,
              onOpenNote: @escaping (URL) -> Void, onNoteChanged: @escaping ([URL]) -> Void,
              onAnswerRecorded: @escaping (URL) -> Void = { _ in }) {
        let day = EveningJournal.day(containing: Date())
        if let window, let model, model.day == day {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = EveningModel(day: day)
        model.onNoteChanged = onNoteChanged
        model.onAnswerRecorded = onAnswerRecorded
        self.model = model
        let window = window ?? makeWindow()
        window.title = model.document.title
        window.contentViewController = NSHostingController(rootView: EveningRootView(
            model: model, recentNotes: recentNotes, capture: capture,
            onOpenNote: onOpenNote, onFilesAdded: onNoteChanged,
            onClose: { [weak window] in window?.close() }
        ))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WimmStudio.Evening")
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // The view saves on disappear; dropping the controller releases the recorder and PhotoKit caches.
        window?.contentViewController = nil
        model = nil
    }
}
