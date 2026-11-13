import SwiftUI

/// "Друг" as a teleprompter: the agent's current reply sits in the top-left
/// corner, near the camera but beside the face rather than over it; the mirrored
/// camera fills the window behind it. One record button below; each
/// recording is a normal Wimm note.
struct FriendView: View {
    let conversation: FriendConversation
    let mirror: FriendMirror
    let capture: CaptureSession
    @State private var showsMirror = UserDefaults.standard.object(forKey: "WimmStudio.friendMirror") as? Bool ?? true
    @State private var autoRecordAfterTurn = UserDefaults.standard.object(forKey: ShoulderSpeaker.autoRecordAfterTurnKey) as? Bool ?? true
    @State private var autoRecordTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                VStack(spacing: 0) {
                    if let lines = conversation.dialogue {
                        ShouldersView(lines: lines, speakingLine: conversation.speakingLine, dimmed: conversation.awaitingReply)
                            .frame(maxHeight: proxy.size.height * 0.75, alignment: .top)
                        Spacer(minLength: 12)
                        status
                            .fixedSize()
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(.bottom, 10)
                    } else {
                        HStack(alignment: .top, spacing: 0) {
                            // Top-left, beside the face rather than over the head: a third of the
                            // width at most, so the centre of the mirror stays clear.
                            prompter
                                .frame(width: max(260, proxy.size.width * 0.34), alignment: .topLeading)
                                .frame(maxHeight: proxy.size.height * 0.7, alignment: .top)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 16)
                    }
                    bottomBar
                }
                .padding(.horizontal, 24)
                // Below the transparent title bar, as close to the camera as the window allows.
                .padding(.top, 34)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 560, minHeight: 480)
        .environment(\.colorScheme, .dark)
        .onAppear {
            conversation.start()
            if showsMirror { Task { await mirror.start() } }
        }
        .onDisappear {
            conversation.stop()
            mirror.stop()
        }
        .onChange(of: showsMirror) { _, on in
            UserDefaults.standard.set(on, forKey: "WimmStudio.friendMirror")
            if on { Task { await mirror.start() } } else { mirror.stop() }
        }
        .onChange(of: capture.isRecording) { _, recording in
            // The microphone must not hear the friend's voice.
            autoRecordTask?.cancel()
            autoRecordTask = nil
            if recording { conversation.interrupt() } else { conversation.answerRecorded() }
        }
        .onChange(of: conversation.isSpeaking) { wasSpeaking, nowSpeaking in
            autoRecordTask?.cancel()
            autoRecordTask = nil
            // Auto-start recording after Angel & Demon finish speaking their turn (with acoustic safety delay).
            guard wasSpeaking, !nowSpeaking,
                  autoRecordAfterTurn,
                  conversation.dialogue != nil,
                  conversation.shouldersActivity == nil,
                  !capture.isRecording, !capture.isBusy, !capture.isSending else { return }
            autoRecordTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled,
                      autoRecordAfterTurn,
                      !conversation.isSpeaking,
                      conversation.shouldersActivity == nil,
                      !capture.isRecording, !capture.isBusy, !capture.isSending else { return }
                await capture.start()
            }
        }
        .onChange(of: autoRecordAfterTurn) { _, on in
            UserDefaults.standard.set(on, forKey: ShoulderSpeaker.autoRecordAfterTurnKey)
            if !on {
                autoRecordTask?.cancel()
                autoRecordTask = nil
            }
        }
    }

    @ViewBuilder private var background: some View {
        if showsMirror, mirror.state == .running || mirror.state == .starting {
            FriendMirrorView(session: mirror.session, isRunning: mirror.state == .running)
                .ignoresSafeArea()
        } else {
            ZStack {
                Color(white: 0.09).ignoresSafeArea()
                if !showsMirror {
                    // An off mirror must say so and how to bring it back.
                    Button { showsMirror = true } label: {
                        Label("Включить зеркало", systemImage: "video.fill")
                            .font(.title3)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                }
            }
        }
    }

    // MARK: - Prompter

    private var prompter: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A short reply hugs its text; a long one scrolls inside the height cap.
            // A teleprompter should not scroll: shrink the type first, scroll only past the smallest size.
            ViewThatFits(in: .vertical) {
                replyText(size: 26)
                replyText(size: 22)
                replyText(size: 19)
                ScrollView { replyText(size: 19) }
            }
            status
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func replyText(size: CGFloat) -> some View {
        Group {
            if conversation.reply.isEmpty {
                Text("Начни разговор в чате со скиллом wimm-conversation — реплики Друга появятся здесь.")
                    .foregroundStyle(.secondary)
            } else {
                Text(FriendConversation.attributed(conversation.reply))
            }
        }
        .font(.system(size: size, weight: .regular, design: .serif))
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .opacity(conversation.awaitingReply ? 0.45 : 1)
        .animation(.easeInOut(duration: 0.3), value: conversation.awaitingReply)
    }

    private var status: some View {
        HStack(spacing: 8) {
            if conversation.isSpeaking {
                // The live sound icon sits on the line being read (ShouldersView); here only the stop.
                if conversation.dialogue == nil {
                    Image(systemName: "speaker.wave.2.fill").symbolEffect(.variableColor.iterative, isActive: true)
                }
                Button("Замолчать") { conversation.interrupt() }
            } else if capture.isRecording {
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Твой ход")
            } else if let activity = conversation.shouldersActivity {
                ProgressView().controlSize(.small)
                Text(activity)
            } else if conversation.awaitingReply {
                ProgressView().controlSize(.small)
                Text(conversation.dialogue == nil ? "Друг слушает…" : "Ангел и Демон слушают…")
            } else {
                Text(conversation.dialogue == nil ? "Друг" : "Ангел и Демон")
                if let at = conversation.receivedAt { Text(at, style: .time) }
                if !conversation.reply.isEmpty, conversation.speaksAloud {
                    Button("Повторить") { conversation.replay() }
                }
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .buttonStyle(.link)
    }

    // MARK: - Recording

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if capture.isRecording, !capture.liveText.isEmpty {
                Text(capture.liveText)
                    .font(.title3)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: 700)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if let error = capture.errorMessage ?? conversation.shouldersError ?? mirrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.black.opacity(0.55), in: Capsule())
            }
            HStack(spacing: 20) {
                barToggle(isOn: Binding(get: { conversation.speaksAloud }, set: { conversation.speaksAloud = $0 }),
                          on: "speaker.wave.2.fill", off: "speaker.slash.fill", help: "Озвучивать реплики Друга")
                recordButton
                if conversation.dialogue != nil {
                    barToggle(isOn: $autoRecordAfterTurn,
                              on: "waveform.badge.mic", off: "mic.slash",
                              help: "Автостарт записи после реплик Ангела и Демона")
                }
                barToggle(isOn: $showsMirror, on: "video.fill", off: "video.slash.fill",
                          help: "Показывать камеру как зеркало (ничего не записывается)")
            }
            .padding(.horizontal, 22).padding(.vertical, 8)
            .background(Color.black.opacity(0.45), in: Capsule())
        }
    }

    /// FaceTime-style: on is a quiet translucent circle; off is a light circle
    /// with a slashed icon, so the unusual state is the one that stands out.
    private func barToggle(isOn: Binding<Bool>, on: String, off: String, help: String) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            Image(systemName: isOn.wrappedValue ? on : off)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.black.opacity(0.85))
                .background(isOn.wrappedValue ? Color.white.opacity(0.16) : Color.white.opacity(0.92), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var recordButton: some View {
        Button {
            capture.toggle()
        } label: {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 58, height: 58)
                if capture.isRecording {
                    Circle()
                        .fill(.red.opacity(0.35))
                        .frame(width: 58, height: 58)
                        .scaleEffect(1 + CGFloat(min(capture.level * 4, 0.3)))
                        .animation(.easeOut(duration: 0.1), value: capture.level)
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 22, height: 22)
                } else {
                    Circle().fill(.red).frame(width: 46, height: 46)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .help(capture.isRecording ? "Остановить запись (пробел, ⌥W)" : "Записать ответ (пробел, ⌥W)")
        .disabled(capture.isBusy || capture.isSending)
    }

    private var mirrorMessage: String? {
        guard showsMirror else { return nil }
        switch mirror.state {
        case .denied: return "Нет доступа к камере: Системные настройки → Конфиденциальность → Камера."
        case .unavailable: return "Камера не найдена."
        default: return nil
        }
    }
}
