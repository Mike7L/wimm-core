import Carbon
import AppKit

// Centralized, simple global hotkey center using Carbon's RegisterEventHotKey.
// - One event handler installed once per app.
// - Each registration returns a Token you can hold and later unregister.

private func hotKeyCallback(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    var hk = EventHotKeyID()
    GetEventParameter(event,
                      EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID),
                      nil,
                      MemoryLayout<EventHotKeyID>.size,
                      nil,
                      &hk)
    // Carbon delivers application-target hotkey events on the main thread.
    MainActor.assumeIsolated {
        HotKeyCenter.shared.handle(id: hk.id)
    }
    return noErr
}

@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    public struct Token: Hashable { let id: UInt32 }

    public enum KeyCode {
    public static let escape: UInt32 = UInt32(kVK_Escape)
    public static let f9: UInt32 = UInt32(kVK_F9)
    public static let ansiW: UInt32 = UInt32(kVK_ANSI_W)
    public static let ansiV: UInt32 = UInt32(kVK_ANSI_V)
    public static let ansiC: UInt32 = UInt32(kVK_ANSI_C)
    public static let ansiX: UInt32 = UInt32(kVK_ANSI_X)
    public static let ansiH: UInt32 = UInt32(kVK_ANSI_H)
    // Common local keys (use UInt32 here; cast as needed for NSEvent.keyCode)
    public static let space: UInt32      = UInt32(kVK_Space)
    public static let leftArrow: UInt32  = UInt32(kVK_LeftArrow)
    public static let rightArrow: UInt32 = UInt32(kVK_RightArrow)
    }

    private var nextID: UInt32 = 1
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false

    private init() { installHandlerIfNeeded() }

    private func installHandlerIfNeeded() {
        if handlerInstalled { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyCallback, 1, &spec, nil, nil)
        handlerInstalled = true
    }

    @discardableResult
    public func register(keyCode: UInt32, flags: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) -> Token? {
        installHandlerIfNeeded()
        let id = nextID; nextID &+= 1
        var ref: EventHotKeyRef? = nil
        let eventID = EventHotKeyID(signature: OSType(0x77696D6D), id: id) // 'wimm'
        let status = RegisterEventHotKey(keyCode, Self.carbonMask(from: flags), eventID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        actions[id] = { DispatchQueue.main.async { handler() } }
        return Token(id: id)
    }

    private static func carbonMask(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    public func unregister(_ token: Token) {
        guard let ref = refs[token.id] else { return }
        UnregisterEventHotKey(ref)
        refs.removeValue(forKey: token.id)
        actions.removeValue(forKey: token.id)
    }

    fileprivate func handle(id: UInt32) { actions[id]?() }
}
