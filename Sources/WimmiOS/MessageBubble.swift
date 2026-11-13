#if os(iOS)
import SwiftUI
import AVFoundation

struct MessageBubble: View {
    let message: ChatMessage
    @StateObject private var player = AudioPlayerController()
    @State private var isPlaying = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isRecordingType {
                Spacer(minLength: 40)
            }
            
            VStack(alignment: isRecordingType ? .trailing : .leading, spacing: 0) {
                bubbleContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(bubbleBackground)
                    .cornerRadius(18, corners: bubbleCorners)
                    .frame(maxWidth: UIScreen.main.bounds.width * 0.75, alignment: isRecordingType ? .trailing : .leading)
            }
            
            if !isRecordingType {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Icon and Title
            HStack(spacing: 6) {
                Text(messageIcon)
                    .font(.system(size: 16))
                Text(messageTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isRecordingType ? .white : .primary)
            }
            
            // Main content
            switch message.content {
            case .audio(let url, let duration):
                if isRecordingType {
                    inlineAudioPlayer(url: url, duration: duration)
                } else {
                    Text(L10n.iOS.Chat.audioLabel(duration: formatDuration(duration)))
                        .font(.body)
                        .foregroundColor(bubbleTextColor)
                }
                
            case .text(let text):
                Text(text)
                    .font(.body)
                    .foregroundColor(bubbleTextColor)
                
            case .mixed(let url, let text):
                VStack(alignment: .leading, spacing: 8) {
                    if isRecordingType {
                        inlineAudioPlayer(url: url, duration: 0)
                    }
                    Text(text)
                        .font(.body)
                        .foregroundColor(bubbleTextColor)
                }
            }
            
            // Location (if available)
            if let location = message.location {
                HStack(spacing: 4) {
                    Text("📍")
                        .font(.caption)
                    Text(location.placeName ?? L10n.iOS.Chat.location)
                        .font(.caption)
                        .foregroundColor(bubbleTextColor.opacity(0.8))
                }
                .padding(.top, 4)
            }
            
            // Timestamp with save status
            HStack(spacing: 4) {
                InlineSaveStatusIndicator(
                    isSaved: message.isSaved,
                    textColor: bubbleTextColor
                )
                
                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(bubbleTextColor.opacity(0.7))
            }
            .padding(.top, 4)
            .animation(.easeInOut(duration: 0.3), value: message.isSaved)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.iOS.Chat.accessibilitySavedAt(
                time: message.timestamp.formatted(date: .omitted, time: .shortened),
                isSaved: message.isSaved
            ))
        }
    }
    
    // MARK: - Computed Properties
    
    @ViewBuilder
    private func inlineAudioPlayer(url: URL, duration: Double) -> some View {
        HStack(spacing: 12) {
            // Play/Pause button
            Button {
                togglePlayback(url: url)
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 4) {
                // Waveform
                if let levels = extractWaveformLevels(url: url) {
                    ModernWaveform(
                        levels: levels,
                        barCount: 20,
                        height: 24,
                        barWidth: 2,
                        color: .white
                    )
                } else {
                    ModernWaveform(
                        levels: [],
                        barCount: 20,
                        height: 24,
                        barWidth: 2,
                        color: .white
                    )
                }
                
                // Duration
                HStack {
                    if isPlaying {
                        Text(formatDuration(player.currentTime))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                        Text("/")
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Text(formatDuration(duration > 0 ? duration : player.duration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
        }
        .onDisappear {
            player.stop()
        }
    }
    
    private var bubbleBackground: some View {
        Group {
            switch message.type {
            case .recording:
                Color(red: 0, green: 122.0/255, blue: 1) // #007AFF
            case .transcription:
                Color(red: 233.0/255, green: 233.0/255, blue: 235.0/255) // #E9E9EB
            case .system:
                Color.secondary.opacity(0.2)
            }
        }
    }
    
    private var bubbleTextColor: Color {
        switch message.type {
        case .recording:
            return .white
        case .transcription, .system:
            return .black
        }
    }
    
    private var messageIcon: String {
        switch message.type {
        case .recording:
            return "🎙️"
        case .transcription:
            return "🎤"
        case .system:
            return "ℹ️"
        }
    }
    
    private var messageTitle: String {
        switch message.type {
        case .recording:
            return L10n.iOS.Chat.recording
        case .transcription:
            return L10n.iOS.Chat.transcription
        case .system:
            return L10n.iOS.Chat.system
        }
    }
    
    private var isRecordingType: Bool {
        if case .recording = message.type {
            return true
        }
        return false
    }
    
    private var bubbleCorners: UIRectCorner {
        switch message.type {
        case .recording:
            return [.topLeft, .topRight, .bottomLeft]
        case .transcription, .system:
            return [.topLeft, .topRight, .bottomRight]
        }
    }
    
    private func togglePlayback(url: URL) {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play(url: url)
            isPlaying = true
        }
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", minutes, secs)
    }
    
    private func extractWaveformLevels(url: URL) -> [Float]? {
        // TODO: Extract actual waveform data from audio file
        // For now, return nil to show empty waveform
        return nil
    }
}

// Extension to apply corner radius to specific corners
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - Preview
#Preview("Recording Message (Saved)") {
    let recordingMessage = ChatMessage(
        type: .recording(ChatMessageRecording(
            url: URL(fileURLWithPath: "/tmp/test.m4a"),
            duration: 45.3,
            createdAt: Date()
        )),
        content: .audio(
            url: URL(fileURLWithPath: "/tmp/test.m4a"),
            duration: 45.3
        ),
        location: ChatMessage.Location(
            latitude: 37.7749,
            longitude: -122.4194,
            placeName: "San Francisco"
        ),
        isSaved: true
    )
    
    MessageBubble(message: recordingMessage)
        .padding()
}

#Preview("Recording Message (Saving)") {
    let recordingMessage = ChatMessage(
        type: .recording(ChatMessageRecording(
            url: URL(fileURLWithPath: "/tmp/test.m4a"),
            duration: 45.3,
            createdAt: Date()
        )),
        content: .audio(
            url: URL(fileURLWithPath: "/tmp/test.m4a"),
            duration: 45.3
        ),
        location: ChatMessage.Location(
            latitude: 37.7749,
            longitude: -122.4194,
            placeName: "San Francisco"
        ),
        isSaved: false
    )
    
    MessageBubble(message: recordingMessage)
        .padding()
}

#Preview("Transcription Message") {
    let transcriptionMessage = ChatMessage(
        type: .transcription("This is a sample transcription of the recorded audio. It shows how the text will appear in the chat interface."),
        content: .text("This is a sample transcription of the recorded audio. It shows how the text will appear in the chat interface.")
    )
    
    MessageBubble(message: transcriptionMessage)
        .padding()
}

#Preview("System Message") {
    let systemMessage = ChatMessage(
        type: .system("Recording saved successfully"),
        content: .text("Recording saved successfully")
    )
    
    MessageBubble(message: systemMessage)
        .padding()
}

#Preview("Mixed Content") {
    let mixedMessage = ChatMessage(
        type: .recording(ChatMessageRecording(
            url: URL(fileURLWithPath: "/tmp/test.m4a"),
            duration: 30.0,
            createdAt: Date()
        )),
        content: .mixed(
            audio: URL(fileURLWithPath: "/tmp/test.m4a"),
            text: "Quick note about the meeting"
        )
    )
    
    MessageBubble(message: mixedMessage)
        .padding()
}
#endif
