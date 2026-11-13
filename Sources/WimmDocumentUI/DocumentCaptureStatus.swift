import SwiftUI

public struct DocumentCaptureStatus: View {
    let capture: CaptureSession
    public init(capture: CaptureSession) { self.capture = capture }
    public var body: some View {
        if capture.phase != .idle {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(capture.isRecording ? "Идёт запись" : "Сохранение…").font(.caption.weight(.semibold))
                    if let anchor = capture.listeningAnchor {
                        Text("“\(anchor.target.selector.quote)”").font(.caption).lineLimit(1)
                    }
                    Spacer()
                    Button("Отправить и продолжить") { Task { await capture.send() } }
                        .disabled(!capture.isRecording || capture.isSending)
                    Button("Стоп") { Task { await capture.stop() } }.disabled(!capture.isRecording || capture.isSending)
                }
                if !capture.liveText.isEmpty {
                    Text(String(capture.liveText.suffix(400))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                Text("Щёлкните по предложению, чтобы привязать следующие слова к нему.")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(10).background(Color.red.opacity(0.06))
        }
    }
}

/// Shared recording switch used across Wimm HUD, Reader sidebar, and Studio HUD:
/// a light knob stamped with a mic, and a red track that pulses while recording.
public struct RecordingSwitchStyle: ToggleStyle {
    public var showsLabel: Bool
    public var pulseOn: Bool
    public var offTrack: Color
    public var hitSize: CGSize?
    /// Input level 0…1; while on, a halo behind the track breathes with it.
    public var level: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    public static let trackSize = CGSize(width: 38, height: 22)
    private static let knobInset: CGFloat = 2

    public init(
        showsLabel: Bool,
        pulseOn: Bool,
        offTrack: Color = Color.white.opacity(0.18),
        hitSize: CGSize? = nil,
        level: CGFloat = 0
    ) {
        self.showsLabel = showsLabel
        self.pulseOn = pulseOn
        self.offTrack = offTrack
        self.hitSize = hitSize
        self.level = min(1, max(0, level))
    }

    public func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let knobDiameter = Self.trackSize.height - Self.knobInset * 2
        return Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                if showsLabel { configuration.label }
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn
                            ? AnyShapeStyle(LinearGradient(
                                colors: pulseOn
                                    ? [Color(red: 1.0, green: 0.32, blue: 0.30), Color(red: 0.86, green: 0.10, blue: 0.14)]
                                    : [Color(red: 0.78, green: 0.12, blue: 0.16), Color(red: 0.55, green: 0.05, blue: 0.09)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing))
                            : AnyShapeStyle(offTrack))
                        .shadow(color: isOn ? Color.red.opacity(pulseOn ? 0.75 : 0.2) : .clear, radius: pulseOn ? 6 : 2)
                    Circle()
                        .fill(Color.white.opacity(0.94))
                        .overlay(
                            Image(systemName: "mic.fill")
                                .font(.system(size: knobDiameter * 0.55, weight: .bold))
                                .foregroundStyle(isOn ? Color.red : Color.gray)
                        )
                        .frame(width: knobDiameter, height: knobDiameter)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(Self.knobInset)
                }
                .frame(width: Self.trackSize.width, height: Self.trackSize.height)
                .background(
                    Capsule()
                        .fill(Color.red.opacity(0.4))
                        .scaleEffect(x: 1 + 0.28 * level, y: 1 + 0.6 * level)
                        .opacity(isOn && level > 0 ? 1 : 0)
                        .animation(.easeOut(duration: 0.1), value: level)
                )
                .animation(.easeInOut(duration: 0.9), value: pulseOn)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
            }
            .frame(minWidth: hitSize?.width, minHeight: hitSize?.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
