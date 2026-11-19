import SwiftUI
import WimmDocumentUI

/// What the microphone toggle shows. One rule for the HUD bar and the island pill.
enum MicToggleMode: Equatable {
    case off
    /// Starting or stopping: the click is taken, capture is not running yet.
    case busy
    case quiet
    /// Sound that is not speech.
    case sound
    case speech
    /// Recording is on but the input delivers nothing.
    case trouble
    case vikListening
    case vikThinking(micOpen: Bool)
    case vikSpeaking(micOpen: Bool)

    struct Input: Equatable {
        var isRecording = false
        var isBusy = false
        var level: CGFloat = 0
        var isSpeech = false
        var inputTrouble = false
        var vik: VikAssistant.Phase = .idle
        var vikKeepsMicOpen = false
    }

    /// `LevelMeter` value below which sound draws nothing (RMS ≈ 0.006, −44 dBFS).
    /// Above the silence gate's floor on purpose: room noise must not keep the toggle moving.
    static let soundFloor: CGFloat = 0.16

    static func resolve(_ input: Input) -> MicToggleMode {
        let micOpen = input.vikKeepsMicOpen && input.isRecording
        switch input.vik {
        case .speaking: return .vikSpeaking(micOpen: micOpen)
        case .thinking, .finishing: return .vikThinking(micOpen: micOpen)
        case .listening where input.isRecording && !input.inputTrouble: return .vikListening
        case .listening, .idle, .failed: break
        }
        if input.isBusy { return .busy }
        guard input.isRecording else { return .off }
        if input.inputTrouble { return .trouble }
        if input.isSpeech { return .speech }
        return input.level >= soundFloor ? .sound : .quiet
    }

    /// Modes that move on their own and need a frame clock.
    var animates: Bool {
        switch self {
        case .off, .quiet, .trouble: false
        case .busy, .sound, .speech, .vikListening, .vikThinking, .vikSpeaking: true
        }
    }

    var showsCountdown: Bool { self == .quiet || self == .sound }
}

/// The fill that runs out while quiet after speech is about to send the note.
struct MicToggleCountdown: Equatable {
    /// Share of the track still filled, counted from the microphone.
    var length: CGFloat
    var opacity: CGFloat

    /// Short pauses between phrases stay invisible: nothing shows for the first 3 s.
    static func make(quietSeconds: Double, totalSeconds: Double) -> MicToggleCountdown? {
        guard totalSeconds > 0, quietSeconds < totalSeconds else { return nil }
        let hidden = min(3, totalSeconds * 0.3)
        let opacity = min(1, max(0, (quietSeconds - hidden) / 0.6))
        guard opacity > 0 else { return nil }
        return MicToggleCountdown(length: 1 - quietSeconds / totalSeconds, opacity: opacity)
    }
}

/// Microphone indicator and button: the glyph in the middle is the sound source
/// (microphone, or the speaker while Алёна talks) and sound runs from it to both
/// ends as a row of bars. Background colour says what is going on, the shape of
/// the wave says whose sound it is. One element for the HUD bar and the island pill.
struct MicToggle: View {
    static let barSize = CGSize(width: 56, height: 22)

    let mode: MicToggleMode
    var level: CGFloat = 0
    var countdown: MicToggleCountdown?
    /// A change plays the "note sent, next one started" flash.
    var sendCount: UInt64 = 0
    /// Turning true blinks the surface: Алёна did not answer.
    var failed = false
    /// Length × thickness.
    var trackSize = MicToggle.barSize
    var vertical = false
    /// The indicator is the whole surface of its container (the island pill), which clips it to its own shape.
    var fillsContainer = false

    @State private var motion = Motion()
    @State private var sweepStart: Date?
    @State private var blinkStart: Date?
    /// The glyph is the send icon for a moment after a note went out.
    @State private var showsSend = false

    private static let sweepSeconds = 0.5
    private static let barsPerSide = 5

    var body: some View {
        let thickness = trackSize.height
        let glyphSize = thickness * 0.62
        let transient = sweepStart != nil || blinkStart != nil
        return TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !(mode.animates || transient))) { timeline in
            Canvas { context, size in
                draw(&context, size: size, now: timeline.date, glyphSize: glyphSize)
            }
        }
        .background(baseColor)
        .clipShape(fillsContainer ? AnyShape(Rectangle()) : AnyShape(Capsule()))
        .overlay {
            Image(systemName: showsSend ? "paperplane.fill" : glyph)
                .font(.system(size: glyphSize * 0.82, weight: .bold))
                .foregroundStyle(Color.white.opacity(glyphIsLive || showsSend ? 0.95 : 0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: glyphSize, height: glyphSize)
        }
        .frame(width: vertical ? thickness : trackSize.width, height: vertical ? trackSize.width : thickness)
        .animation(.easeInOut(duration: 0.3), value: mode)
        .onChange(of: sendCount) { _, _ in
            let start = Date()
            sweepStart = start
            withAnimation { showsSend = true }
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard sweepStart == start else { return }
                sweepStart = nil
                try? await Task.sleep(for: .milliseconds(400))
                guard sweepStart == nil else { return }
                withAnimation { showsSend = false }
            }
        }
        .onChange(of: failed) { _, isFailed in
            guard isFailed else { return }
            let start = Date()
            blinkStart = start
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                if blinkStart == start { blinkStart = nil }
            }
        }
    }

    // MARK: - Look

    private static let red = Color(red: 0.43, green: 0.07, blue: 0.09)
    private static let redFill = Color(red: 0.85, green: 0.22, blue: 0.23)
    private static let amber = Color(red: 0.82, green: 0.52, blue: 0.05)
    private static let violet = Color(red: 0.24, green: 0.20, blue: 0.54)
    private static let violetLight = Color(red: 0.50, green: 0.47, blue: 0.87)
    private static let gray = Color(white: 0.53)

    private var baseColor: Color {
        switch mode {
        // The pill is already black; in the bar the resting button is a quiet chip.
        case .off, .busy: fillsContainer ? Color.clear : Color.white.opacity(0.16)
        case .quiet, .sound, .speech: Self.red
        case .trouble: Color(white: 0.34)
        case .vikListening, .vikThinking, .vikSpeaking: Self.violet
        }
    }

    private var glyph: String {
        switch mode {
        case .trouble: "exclamationmark"
        case .vikSpeaking: "speaker.wave.2.fill"
        case .vikThinking(let micOpen): micOpen ? "mic.fill" : "mic.slash.fill"
        case .off, .busy, .quiet, .sound, .speech, .vikListening: "mic.fill"
        }
    }

    /// The source is open (or needs attention), as opposed to resting or closed.
    private var glyphIsLive: Bool {
        switch mode {
        case .off, .busy: false
        case .quiet, .sound, .speech, .trouble, .vikListening, .vikSpeaking: true
        case .vikThinking(let micOpen): micOpen
        }
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize, now: Date, glyphSize: CGFloat) {
        let t = now.timeIntervalSinceReferenceDate
        let heard = min(1, max(0, (level - MicToggleMode.soundFloor) / (1 - MicToggleMode.soundFloor)) * 1.8)
        let target: CGFloat
        switch mode {
        case .speech, .vikListening: target = max(0.18, heard)
        // Noise stays low: tall bars are for speech.
        case .sound: target = heard * 0.45
        case .off, .busy, .quiet, .trouble, .vikThinking, .vikSpeaking: target = 0
        }
        motion.step(level: target, heat: mode == .speech ? 1 : 0, now: now)
        let length = vertical ? size.height : size.width
        let thickness = vertical ? size.width : size.height
        let whole = CGRect(origin: .zero, size: size)

        // A stretch of the surface centred on the glyph, as a share of the length.
        func centered(_ share: CGFloat) -> CGRect {
            let extent = length * share
            return vertical
                ? CGRect(x: 0, y: (length - extent) / 2, width: size.width, height: extent)
                : CGRect(x: (length - extent) / 2, y: 0, width: extent, height: size.height)
        }

        switch mode {
        case .speech, .sound:
            if motion.heat > 0.01 { context.fill(Path(whole), with: .color(Self.amber.opacity(motion.heat))) }
        case .vikThinking:
            context.fill(Path(whole), with: .color(Self.violetLight.opacity(0.18 + 0.14 * sin(t * 2.4))))
        case .busy:
            context.fill(Path(whole), with: .color(Color.white.opacity(0.08 + 0.08 * sin(t * 5))))
        case .off, .quiet, .trouble, .vikListening, .vikSpeaking:
            break
        }

        if mode.showsCountdown, let countdown, countdown.length > 0 {
            context.fill(Path(centered(countdown.length)), with: .color(Self.redFill.opacity(countdown.opacity)))
        }

        drawBars(&context, size: size, length: length, thickness: thickness, glyphSize: glyphSize, t: t)

        if let sweepStart {
            let p = CGFloat(now.timeIntervalSince(sweepStart) / Self.sweepSeconds)
            if p >= 0, p < 1 {
                context.fill(Path(centered(min(1, p * 1.3))), with: .color(.white.opacity(0.85 * (1 - p))))
            }
        }

        if let blinkStart {
            let elapsed = now.timeIntervalSince(blinkStart)
            if (0..<0.2).contains(elapsed) || (0.4..<0.6).contains(elapsed) {
                context.fill(Path(whole), with: .color(Self.gray.opacity(0.9)))
            }
        }
    }

    /// Bars on both sides of the glyph. Bar `i` shows what the source did `i` frames ago, so the wave travels outward.
    private func drawBars(_ context: inout GraphicsContext, size: CGSize, length: CGFloat,
                          thickness: CGFloat, glyphSize: CGFloat, t: Double) {
        switch mode {
        case .off, .busy, .trouble: return
        case .quiet, .sound, .speech, .vikListening, .vikThinking, .vikSpeaking: break
        }
        let width: CGFloat = thickness >= 20 ? 2 : 1.75
        let gap = width
        let tallest = thickness - 6
        let first = glyphSize / 2 + 2.5 + width / 2
        for index in 0..<Self.barsPerSide {
            let i = Double(index)
            let amp: CGFloat
            let opacity: CGFloat
            switch mode {
            case .vikSpeaking:
                // A smooth wave, unlike the ragged bars of the owner's own voice.
                amp = CGFloat(0.5 + 0.45 * sin(t * 7 - i))
                opacity = 0.95
            case .vikThinking:
                amp = CGFloat(max(0, sin(t * 2.6 - i * 0.8))) * 0.35
                opacity = 0.4 + 0.5 * amp / 0.35
            default:
                amp = motion.past(index) * CGFloat(1 - i * 0.12)
                opacity = 0.45 + 0.5 * min(1, amp * 3)
            }
            let extent = max(width, amp * tallest)
            let offset = first + CGFloat(index) * (width + gap)
            for side: CGFloat in [-1, 1] {
                let along = length / 2 + side * offset
                let rect = vertical
                    ? CGRect(x: (size.width - extent) / 2, y: along - width / 2, width: extent, height: width)
                    : CGRect(x: along - width / 2, y: (size.height - extent) / 2, width: width, height: extent)
                context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(.white.opacity(opacity)))
            }
        }
    }

    /// Fast attack, slow release, plus the last few frames of the level for the travelling wave.
    private final class Motion {
        var heat: CGFloat = 0
        private var level: CGFloat = 0
        private var history = [CGFloat](repeating: 0, count: MicToggle.barsPerSide)
        private var last: Date?

        func step(level target: CGFloat, heat heatTarget: CGFloat, now: Date) {
            guard now != last else { return }
            let dt = min(0.1, max(0, last.map { now.timeIntervalSince($0) } ?? 0))
            last = now
            level += (target - level) * CGFloat(1 - exp(-dt / (target > level ? 0.03 : 0.12)))
            heat += (heatTarget - heat) * CGFloat(1 - exp(-dt / 0.12))
            history.removeLast()
            history.insert(level, at: 0)
        }

        func past(_ frames: Int) -> CGFloat { history[min(frames, history.count - 1)] }
    }
}

/// `MicToggle` bound to the capture session and Алёна. It reads them in its own
/// body, so the 10 Hz level only redraws the toggle, not the whole HUD.
struct CaptureMicToggle: View {
    let capture: CaptureSession
    var vik: VikAssistant?
    var trackSize = MicToggle.barSize
    var vertical = false
    var fillsContainer = false
    var hitSize: CGSize?
    /// The collapsed pill takes its clicks in the panel, not in the view.
    var interactive = true

    var body: some View {
        let toggle = MicToggle(
            mode: MicToggleMode.resolve(.init(
                isRecording: capture.isRecording,
                isBusy: capture.isBusy,
                level: CGFloat(capture.level),
                isSpeech: capture.isSpeech,
                inputTrouble: capture.inputTrouble,
                vik: vik?.phase ?? .idle,
                vikKeepsMicOpen: vik?.keepMicOpen ?? false)),
            level: CGFloat(capture.level),
            countdown: capture.pendingSend.flatMap {
                MicToggleCountdown.make(quietSeconds: $0.quietSeconds, totalSeconds: $0.totalSeconds)
            },
            sendCount: capture.sendCount,
            failed: vik?.phase == .failed,
            trackSize: trackSize,
            vertical: vertical,
            fillsContainer: fillsContainer)
        if interactive {
            Button { capture.toggle() } label: {
                toggle
                    .frame(minWidth: hitSize?.width, minHeight: hitSize?.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut("x", modifiers: [])
            .help(capture.isRecording ? "Stop recording (⌥W; X in HUD)" : "Start recording (⌥W; X in HUD)")
            .accessibilityLabel(capture.isRecording ? "Recording" : "Record")
            .accessibilityAddTraits(.isToggle)
            .accessibilityValue(capture.isRecording ? "On" : "Off")
        } else {
            toggle.accessibilityHidden(true)
        }
    }
}
