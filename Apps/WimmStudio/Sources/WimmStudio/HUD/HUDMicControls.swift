import SwiftUI
import WimmDocumentUI
import WimmInfrastructure

/// Pure icon/tooltip helpers for the HUD microphone source & Mic Mode controls.
enum HUDMicIcon {
    static func symbol(for device: AudioInputOption?) -> String {
        guard let device else { return "mic" }
        if device.name.localizedCaseInsensitiveContains("airpods") { return "airpodspro" }
        if device.transport == "bluetooth" { return "headphones" }
        if device.isBuiltIn { return "laptopcomputer" }
        return "mic.fill"
    }

    static func inputTooltip(current: AudioInputOption?, target: AudioInputOption?) -> String {
        guard let current else { return "Микрофон не найден" }
        if let target {
            return "Микрофон: \(current.name) · Нажать → \(target.name) (ПКМ — список)"
        }
        return "Микрофон: \(current.name)"
    }

    static func micModeTooltip(
        active: CaptureMicrophoneMode,
        preferred: CaptureMicrophoneMode,
        isRecording: Bool
    ) -> String {
        if isRecording {
            return "Режим микрофона: \(active.displayName) — открыть выбор"
        }
        return "Режим микрофона: \(preferred.displayName) — доступен во время записи"
    }
}

/// Isolated control strip for input device switching and macOS Mic Mode
/// so `@Observable` reads stay scoped to this subview.
struct HUDMicControls: View {
    let capture: CaptureSession
    let showsSource: Bool
    let showsMode: Bool

    var body: some View {
        let current = capture.displayedInputDevice
        let target = capture.toggleInputTarget
        let mode = capture.isRecording ? capture.activeMicrophoneMode : capture.preferredMicrophoneMode

        HStack(spacing: 2) {
            if showsSource {
                Button {
                    capture.toggleInputDevice()
                } label: {
                    Image(systemName: HUDMicIcon.symbol(for: current))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(sourceTint(for: current))
                .opacity(capture.isSwitchingInput ? 0.45 : (capture.canToggleInputDevice ? 1 : 0.7))
                .disabled(!capture.canToggleInputDevice)
                .help(HUDMicIcon.inputTooltip(current: current, target: target))
                .accessibilityLabel(HUDMicIcon.inputTooltip(current: current, target: target))
                .contextMenu {
                    ForEach(capture.availableInputDevices) { device in
                        Button {
                            capture.selectInputPreference(
                                device.isBuiltIn ? .builtInOnly : .device(uid: device.uid)
                            )
                        } label: {
                            if current?.uid == device.uid {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                    Divider()
                    Button {
                        capture.selectInputPreference(.systemDefault)
                    } label: {
                        if capture.inputPreference == .systemDefault {
                            Label("По умолчанию системы", systemImage: "checkmark")
                        } else {
                            Text("По умолчанию системы")
                        }
                    }
                    Divider()
                    Button("Режим микрофона…") {
                        capture.showSystemMicrophoneModes()
                    }
                    .disabled(!capture.isRecording)
                }
            }

            if showsMode {
                Button {
                    capture.showSystemMicrophoneModes()
                } label: {
                    Image(systemName: "waveform.badge.mic")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .foregroundStyle(mode == .voiceIsolation ? Color.green : Color.secondary)
                .opacity(capture.isRecording ? 1 : 0.4)
                .disabled(!capture.isRecording)
                .help(HUDMicIcon.micModeTooltip(
                    active: capture.activeMicrophoneMode,
                    preferred: capture.preferredMicrophoneMode,
                    isRecording: capture.isRecording
                ))
                .accessibilityLabel(HUDMicIcon.micModeTooltip(
                    active: capture.activeMicrophoneMode,
                    preferred: capture.preferredMicrophoneMode,
                    isRecording: capture.isRecording
                ))
            }
        }
    }

    private func sourceTint(for device: AudioInputOption?) -> Color {
        if device?.isHeadset == true {
            return capture.isRecording ? .orange : .orange.opacity(0.85)
        }
        return capture.isRecording ? .primary : .secondary
    }
}
