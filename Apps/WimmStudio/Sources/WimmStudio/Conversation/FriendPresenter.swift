import AppKit
import SwiftUI

/// Owns the "Друг" window, which also hosts the angel-and-demon conversation.
/// Closing it stops the camera and the voice.
@MainActor
final class FriendPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var conversation: FriendConversation?
    private var mirror: FriendMirror?

    func owns(_ candidate: NSWindow) -> Bool { window === candidate }

    func noteTranscribed(_ note: URL, text: String) {
        conversation?.answerTranscribed(note, text: text)
    }

    enum Mode {
        case friend
        /// The built-in angel and demon, talking about this document (nil: none open).
        case shoulders(document: URL?)
    }

    func show(capture: CaptureSession, mode: Mode = .friend) {
        if let window, window.contentViewController != nil, let conversation {
            apply(mode, to: conversation, in: window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = window ?? makeWindow()
        let conversation = FriendConversation(), mirror = FriendMirror()
        apply(mode, to: conversation, in: window)
        self.conversation = conversation
        self.mirror = mirror
        let controller = NSHostingController(rootView: FriendView(
            conversation: conversation, mirror: mirror, capture: capture
        ))
        // Otherwise the controller shrinks the window to the view's minimum size.
        controller.sizingOptions = []
        window.contentViewController = controller
        if window.frame.width < 700 { window.setContentSize(NSSize(width: 900, height: 680)); window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func apply(_ mode: Mode, to conversation: FriendConversation, in window: NSWindow) {
        switch mode {
        case .friend:
            conversation.stopShoulders()
            window.title = "Друг"
        case .shoulders(let document):
            conversation.startShoulders(document: document)
            window.title = "Ангел и Демон"
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Друг"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WimmStudio.Friend")
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        conversation?.stop()
        mirror?.stop()
        conversation = nil
        mirror = nil
        window?.contentViewController = nil
    }
}
