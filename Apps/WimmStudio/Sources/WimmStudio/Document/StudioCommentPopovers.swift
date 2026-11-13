import SwiftUI
import WimmInfrastructure

/// Floating reaction bar above a selected sentence, word, or dragged span.
struct StudioReactionBar: View {
    let isVoiceListening: Bool
    let onReact: (String) -> Void
    let onComment: (String) -> Void
    let onEditBlock: () -> Void
    let onCancel: () -> Void

    @State private var isWritingCustom = false
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isVoiceListening {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("Listening for voice comment on this selection…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }

            HStack(spacing: 4) {
                ForEach(DocumentReaction.allCases, id: \.rawValue) { reaction in
                    Button {
                        onReact(reaction.emoji)
                    } label: {
                        Text(reaction.emoji)
                            .font(.system(size: 15))
                            .frame(width: 28, height: 26)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(reaction.instruction)
                }

                Divider().frame(height: 18).padding(.horizontal, 2)

                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        isWritingCustom.toggle()
                        if isWritingCustom { isFocused = true }
                    }
                } label: {
                    Label("Comment", systemImage: "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(Color.primary.opacity(isWritingCustom ? 0.16 : 0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    onEditBlock()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Edit paragraph Markdown")
            }

            if isWritingCustom {
                HStack(spacing: 6) {
                    TextField("Any emoji or comment…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .focused($isFocused)
                        .onSubmit { submit() }

                    Button("Send") { submit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(minWidth: 280)
            }
        }
        .padding(8)
        .onExitCommand { onCancel() }
    }

    private func submit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.count == 1, trimmed.unicodeScalars.first?.properties.isEmojiPresentation == true {
            onReact(trimmed)
        } else {
            onComment(trimmed)
        }
    }
}

/// Popover showing an existing comment/reaction thread and its replies.
struct StudioThreadPopover: View {
    let thread: DocumentCommentThread
    let onReply: (String) -> Void
    let onSetStatus: (DocumentCommentStatus) -> Void
    let onHover: (Bool) -> Void
    let onEngage: () -> Void
    var onOpenSource: (URL) -> Void = { _ in }

    @State private var replyDraft = ""
    @FocusState private var isReplying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let emoji = thread.root.reaction {
                    Text(emoji).font(.system(size: 16))
                }
                if let quote = thread.root.quote, !quote.isEmpty {
                    Text("“\(quote)”")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Text(thread.status.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }

            if let text = thread.root.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 12.5))
            }

            if let via = thread.root.via {
                if let url = StudioNoteLink.referenceURL(via) {
                    Button { onOpenSource(url) } label: {
                        Label("Открыть заметку", systemImage: via.hasPrefix("voice:") ? "waveform" : "doc.text")
                    }.controlSize(.small).help(via)
                } else {
                    Text(via).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if !thread.replies.isEmpty {
                Divider()
                ForEach(thread.replies, id: \.id) { reply in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reply.author == DocumentCommentAuthor.secretary ? "Secretary" : "Owner")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let text = reply.text {
                            Text(text).font(.system(size: 12))
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                TextField("Reply…", text: $replyDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($isReplying)
                    .onChange(of: isReplying) { _, focused in
                        if focused { onEngage() }
                    }
                    .onSubmit { sendReply() }

                Button("Reply") { sendReply() }
                    .controlSize(.small)
                    .disabled(replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                if thread.status != .resolved {
                    Button("Resolve") { onSetStatus(.resolved) }
                        .controlSize(.small)
                }
                Button("Drop") { onSetStatus(.dropped) }
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onHover { onHover($0) }
    }

    private func sendReply() {
        let text = replyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyDraft = ""
        onReply(text)
    }
}
