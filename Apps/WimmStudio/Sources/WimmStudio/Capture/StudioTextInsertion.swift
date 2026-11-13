import AppKit
import ApplicationServices
import Carbon.HIToolbox
import WimmDomain
import WimmInfrastructure

/// ⌥V: write text into whatever the user was last typing in, outside Studio.
/// The text is the running recording's live text, or else the newest note's —
/// the same `Note.insertableText` rule Wimm's HUD and ⌥V use.
@MainActor
final class StudioTextInsertion {
    private var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    init() {
        remember(NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.remember(app) }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private func remember(_ app: NSRunningApplication?) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastExternalApp = app
    }

    /// Which text ⌥V inserts. While capturing it is the live text. After a stop the
    /// live text is still shown, but the note's stored text (`stored`, the local run
    /// once it exists) wins; the live text is only the fallback until then.
    nonisolated static func text(isCapturing: Bool, live: String, stored: String?, newest: String?) -> String? {
        let live = live.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !live.isEmpty else { return newest }
        guard !isCapturing, let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty else { return live }
        let lowered = stored.lowercased()
        let isPlaceholder = lowered.hasPrefix("transcription failed") || lowered == "no text recognized"
            || lowered == "no speech detected" || lowered == "[[no_speech]]"
        return isPlaceholder ? live : stored
    }

    /// True once a file run (or its no-speech verdict) is in the sidecar, i.e. the
    /// stored text is no longer just the promoted live text.
    nonisolated static func fileRunLanded(sidecar: [String: Any]) -> Bool {
        guard let run = TranscriptRuns.transcription(fromSidecar: sidecar) else { return false }
        if run["speechStatus"] as? String == TranscriptionSpeechStatus.noSpeech.rawValue { return true }
        return TranscriptKind.ofProvider(run["provider"] as? String) != nil
    }

    /// Waits, bounded, for the local run of a note that was just closed, then returns its
    /// stored text. On a timeout or a failed run (`landed == false`) this is whatever is
    /// stored (the live text).
    nonisolated static func awaitLocalRun(of file: URL, timeout: TimeInterval = 30) async -> (text: String?, landed: Bool) {
        let metadataURL = FileStore.metadataURL(forRecordingURL: file)
        let deadline = Date().addingTimeInterval(timeout)
        var landed = false
        while !landed {
            let sidecar = (try? Data(contentsOf: metadataURL)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? [:]
            landed = fileRunLanded(sidecar: sidecar)
            if landed || Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return (await TranscriptRepository().transcriptText(for: file), landed)
    }

    /// The popup line for a finished ⌥V, by where the inserted text came from.
    nonisolated static func receipt(closedNote: Bool, localLanded: Bool, hadLive: Bool, reachedApp: Bool) -> String {
        let what: String
        if !hadLive { what = "предыдущая заметка" }
        else if closedNote { what = localLanded ? "локальная расшифровка" : "живой текст (локальная не успела)" }
        else { what = "текст записи" }
        return reachedApp ? "Вставлено: \(what)" : "В буфере: \(what) — нажмите ⌘V"
    }

    /// - Returns: `true` when the text reached the other app; `false` when it
    ///   is only on the pasteboard and the user has to press ⌘V.
    @discardableResult
    func insert(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
        // The hotkey fires with Option still down; a ⌘V posted now would arrive as ⌘⌥V.
        try? await Task.sleep(nanoseconds: 180_000_000)
        guard AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary),
              let app = lastExternalApp, !app.isTerminated else { return false }

        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
           AXUIElementSetAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, trimmed as CFString) == .success {
            return true
        }
        return postPaste(to: app)
    }

    private func postPaste(to app: NSRunningApplication) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return true
    }
}
