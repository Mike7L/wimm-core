import Darwin
import Foundation
import WimmDomain

// MARK: - HUD command

extension WimmTUIRuntime {

    @discardableResult
    static func runHUD(
        container: AppContainer,
        autoProcessAfterRecord: inout Bool
    ) async throws -> Bool {
        var terminal = TerminalRawMode()
        do {
            try terminal.enable()
        } catch {
            print("HUD requires an interactive terminal (TTY): \(error.localizedDescription)")
            return false
        }
        defer {
            terminal.disable()
            print("")
        }

        let controller = try await HUDController.bootstrap(
            dependencies: makeHUDControllerDependencies(container: container),
            autoProcessAfterRecord: autoProcessAfterRecord
        )
        var shouldRender = true
        var nextRenderAt = Date.distantPast
        var lastRenderedFrame: String?

        while true {
            let now = Date()
            let shouldTickRender = now >= nextRenderAt
            if shouldRender || shouldTickRender {
                let state = await controller.viewState()
                autoProcessAfterRecord = state.autoProcessAfterRecord
                let frame = renderHUDFrame(state: state)
                if frame != lastRenderedFrame {
                    renderHUD(frame: frame)
                    lastRenderedFrame = frame
                }
                shouldRender = false
                nextRenderAt = Date().addingTimeInterval(state.recordingSince == nil ? 1.5 : 0.2)
            }

            guard let char = terminal.readCharacter() else { continue }
            guard let action = hudInputAction(for: char) else { continue }
            let effect = await controller.dispatch(action)

            switch effect {
            case .none:
                break
            case .promptTranscriptEdit(let context):
                let editedText = try await promptHUDTranscriptEdit(in: &terminal, context: context)
                _ = await controller.dispatch(.applyTranscriptEdit(editedText))
            case .runExternalAction(let action):
                do {
                    try await runHUDExternalAction(action, in: &terminal, container: container)
                    await controller.completeExternalAction(action, errorMessage: nil)
                } catch {
                    await controller.completeExternalAction(action, errorMessage: String(describing: error))
                }
            case .close:
                return false
            case .exitApp:
                print("Bye!")
                return true
            }
            autoProcessAfterRecord = await controller.viewState().autoProcessAfterRecord
            shouldRender = true
        }
    }
}

// MARK: - Terminal raw mode

struct TerminalRawMode {
    private var original = termios()
    private(set) var isEnabled = false

    mutating func enable() throws {
        guard !isEnabled else { return }
        guard isatty(STDIN_FILENO) == 1 else {
            throw TerminalRawModeError.notTTY
        }

        var attrs = termios()
        guard tcgetattr(STDIN_FILENO, &attrs) == 0 else {
            throw TerminalRawModeError.tcGetAttrFailed(errno: errno)
        }
        original = attrs
        cfmakeraw(&attrs)
        attrs.c_lflag |= tcflag_t(ISIG)
        // Keep output translation so '\n' is rendered as CRLF in TUI.
        attrs.c_oflag |= tcflag_t(OPOST | ONLCR)
        withUnsafeMutablePointer(to: &attrs.c_cc) { ccp in
            let cc = UnsafeMutableRawPointer(ccp).assumingMemoryBound(to: cc_t.self)
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }

        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &attrs) == 0 else {
            throw TerminalRawModeError.tcSetAttrFailed(errno: errno)
        }

        isEnabled = true
        // Use alternate screen buffer for cleaner full-screen HUD rendering.
        print("\u{001B}[?1049h", terminator: "")
        print("\u{001B}[?25l", terminator: "")
        fflush(stdout)
    }

    mutating func disable() {
        guard isEnabled else { return }
        var attrs = original
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &attrs)
        isEnabled = false
        print("\u{001B}[?25h", terminator: "")
        print("\u{001B}[?1049l", terminator: "")
        fflush(stdout)
    }

    func readCharacter() -> Character? {
        guard let first = readByte() else { return nil }

        // Skip ANSI escape sequences (arrows, Home/End, etc.).
        if first == 0x1B {
            if let next = readByte() {
                if next == 0x5B || next == 0x4F {
                    drainEscapeSequence(startingWith: next)
                    return nil
                }
                return nil
            }
            return Character(UnicodeScalar(27))
        }

        let expectedLength: Int
        if first < 0x80 {
            expectedLength = 1
        } else if first & 0b1110_0000 == 0b1100_0000 {
            expectedLength = 2
        } else if first & 0b1111_0000 == 0b1110_0000 {
            expectedLength = 3
        } else if first & 0b1111_1000 == 0b1111_0000 {
            expectedLength = 4
        } else {
            expectedLength = 1
        }

        var bytes: [UInt8] = [first]
        if expectedLength > 1 {
            for _ in 1..<expectedLength {
                guard let b = readByte() else { break }
                bytes.append(b)
            }
        }

        if let decoded = String(data: Data(bytes), encoding: .utf8), let firstChar = decoded.first {
            return firstChar
        }

        return UnicodeScalar(Int(first)).map(Character.init)
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        let count = Darwin.read(STDIN_FILENO, &byte, 1)
        return count > 0 ? byte : nil
    }

    private func drainEscapeSequence(startingWith first: UInt8) {
        var byte: UInt8 = 0
        if first >= 0x40 && first <= 0x7E {
            return
        }
        // Non-blocking with VTIME=1: read pending bytes that belong to the sequence.
        for _ in 0..<12 {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count <= 0 { break }
            // Typical CSI terminators are in [@-~].
            if byte >= 0x40 && byte <= 0x7E { break }
        }
    }
}

enum TerminalRawModeError: LocalizedError {
    case notTTY
    case tcGetAttrFailed(errno: Int32)
    case tcSetAttrFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .notTTY:
            return "stdin is not a TTY"
        case .tcGetAttrFailed(let code):
            return "tcgetattr failed (errno: \(code))"
        case .tcSetAttrFailed(let code):
            return "tcsetattr failed (errno: \(code))"
        }
    }
}
