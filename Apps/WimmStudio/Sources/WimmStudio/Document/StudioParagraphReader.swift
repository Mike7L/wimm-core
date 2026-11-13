import AppKit
import AVFoundation
import SwiftUI
import WimmDocumentUI
import WimmInfrastructure

/// A paragraph reader beside the editing document: large type, a speed control,
/// and previous/next paragraph. Speech is optional because the compact system
/// voice is often hard to follow; silent playback advances by words per minute.
struct StudioParagraphReader: View {
    let speech: PersonalDocumentSpeech
    let document: PersonalDocument
    @Binding var isPresented: Bool

    @AppStorage("WimmStudio.readerRate") private var rate = 1.0
    @AppStorage("WimmStudio.readerSpeaks") private var speaks = false
    @AppStorage("WimmStudio.readerVoiceID") private var voiceID = ""

    @State private var playing = false
    @State private var appliedRate = 1.0
    @FocusState private var keys: Bool

    private let presets: [Double] = [1, 1.25, 1.5, 2]

    private var playbackToken: String {
        let index = speech.index
        let count = speech.paragraphs.count
        return "\(index)/\(count)|\(playing)|\(speaks)|\(String(format: "%.2f", appliedRate))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 12)
            paragraph
            Spacer(minLength: 12)
            controls
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .focusable()
        .focused($keys)
        .focusEffectDisabled()
        .onAppear {
            speech.setVoiceIdentifier(voiceID.isEmpty ? nil : voiceID, restartIfSpeaking: false)
            appliedRate = rate
            speech.setRateMultiplier(rate, restartIfSpeaking: false)
            speech.align(to: document)
            keys = true
            if speech.isSpeaking {
                speaks = true
                playing = true
            }
        }
        .onDisappear { speech.stop() }
        .onChange(of: document.text) { _, _ in speech.align(to: document) }
        .onChange(of: voiceID) { _, id in
            speech.setVoiceIdentifier(id.isEmpty ? nil : id)
        }
        .onChange(of: playing) { _, on in
            guard speaks else { return }
            if on { speech.playCurrent() } else { speech.stop() }
        }
        .onChange(of: speaks) { _, on in
            guard playing else {
                if !on { speech.stop() }
                return
            }
            if on { speech.playCurrent() } else { speech.stop() }
        }
        .onChange(of: speech.speakingBlockID) { _, id in
            if speaks, playing, id == nil { playing = false }
        }
        .task(id: playbackToken) { await runVisualPlayback() }
        .onKeyPress(.leftArrow) {
            speech.retreatParagraph()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard speech.index + 1 < speech.paragraphs.count else {
                playing = false
                if speaks { speech.advanceParagraph() }
                return .handled
            }
            speech.advanceParagraph()
            return .handled
        }
        .onKeyPress(.space) {
            playing.toggle()
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Читалка")
                .font(.system(size: 13, weight: .semibold))
            if !speech.paragraphs.isEmpty {
                Text("\(speech.index + 1) из \(speech.paragraphs.count)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text("← → абзацы · ⌘← ⌘→ · пробел пауза")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Закрыть читалку")
        }
    }

    @ViewBuilder private var paragraph: some View {
        if let current = speech.currentParagraph {
            VStack(alignment: .leading, spacing: 16) {
                if let heading = current.heading, !heading.isEmpty {
                    Text(heading)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(current.text)
                    .font(.system(size: 22, design: .serif))
                    .lineSpacing(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                if speech.index + 1 < speech.paragraphs.count {
                    Text(speech.paragraphs[speech.index + 1].text)
                        .font(.system(size: 15, design: .serif))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .frame(maxWidth: 680, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ContentUnavailableView("Нечего читать", systemImage: "book.closed",
                                   description: Text("В документе нет абзацев, которые можно показать."))
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { speech.retreatParagraph() } label: {
                    Image(systemName: "backward.frame.fill")
                }
                .disabled(speech.paragraphs.isEmpty || (speech.index == 0 && !speech.isSpeaking))
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Предыдущий абзац")

                Button { playing.toggle() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                }
                .disabled(speech.paragraphs.isEmpty)
                .keyboardShortcut(.space, modifiers: [])
                .help(playing ? "Пауза" : "Читать дальше")

                Button {
                    guard speech.index + 1 < speech.paragraphs.count else {
                        playing = false
                        if speaks { speech.advanceParagraph() }
                        return
                    }
                    speech.advanceParagraph()
                } label: {
                    Image(systemName: "forward.frame.fill")
                }
                .disabled(speech.paragraphs.isEmpty || speech.index + 1 >= speech.paragraphs.count)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Следующий абзац")

                Text(String(format: "%.2f×", rate))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 52, alignment: .trailing)
                Slider(value: $rate, in: 0.75...2, step: 0.05, onEditingChanged: { editing in
                    if !editing { applyRate(rate) }
                })
                .frame(width: 140)
                .help(speaks ? "Скорость голоса, до 2×" : "Скорость чтения глазами")

                ForEach(presets, id: \.self) { preset in
                    Button(presetLabel(preset)) { applyRate(preset) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12, weight: abs(rate - preset) < 0.01 ? .semibold : .regular))
                }

                Spacer(minLength: 8)
                Toggle("Вслух", isOn: $speaks)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .buttonStyle(.borderless)

            if speaks {
                voiceRow
            } else {
                Text("\(Int((170 * rate).rounded())) слов в минуту")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var voiceChoices: [DocumentSpeechVoiceChoice] {
        let sample = speech.currentParagraph?.text ?? ""
        let tag = AVPersonalDocumentSpeechSynthesizer.preferredLanguageTag(for: sample)
        return AVPersonalDocumentSpeechSynthesizer.voiceChoices(languagePrefix: String(tag.prefix(2)))
    }

    private var selectedVoiceIsCompact: Bool {
        if voiceID.isEmpty { return !voiceChoices.isEmpty && voiceChoices.allSatisfy(\.isCompact) }
        return voiceChoices.first { $0.id == voiceID }?.isCompact ?? true
    }

    private var voiceRow: some View {
        HStack(spacing: 10) {
            Picker("Голос", selection: $voiceID) {
                Text("Лучший установленный").tag("")
                ForEach(voiceChoices) { voice in
                    Text("\(voice.name) · \(qualityTitle(voice))").tag(voice.id)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)

            if selectedVoiceIsCompact {
                Text("Установлен только стандартный голос — он звучит механически.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Голоса в Настройках…") { openVoiceSettings() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
    }

    private func applyRate(_ preset: Double) {
        rate = preset
        appliedRate = preset
        speech.setRateMultiplier(preset)
    }

    private func presetLabel(_ preset: Double) -> String {
        preset == floor(preset) ? "\(Int(preset))×" : String(format: "%.2f×", preset).replacingOccurrences(of: ".00", with: "")
    }

    private func qualityTitle(_ voice: DocumentSpeechVoiceChoice) -> String {
        switch voice.quality {
        case AVSpeechSynthesisVoiceQuality.premium.rawValue: return "премиум"
        case AVSpeechSynthesisVoiceQuality.enhanced.rawValue: return "улучшенный"
        default: return "стандартный"
        }
    }

    private func openVoiceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems",
            "x-apple.systempreferences:com.apple.preference.universalaccess",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    private func runVisualPlayback() async {
        guard playing, !speaks, let paragraph = speech.currentParagraph else { return }
        let seconds = PersonalDocumentSpeech.visualDwellSeconds(
            wordCount: PersonalDocumentSpeech.wordCount(paragraph.text), rateMultiplier: appliedRate)
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled, playing, !speaks else { return }
        if speech.index + 1 >= speech.paragraphs.count {
            playing = false
        } else {
            speech.advanceParagraph()
        }
    }
}
