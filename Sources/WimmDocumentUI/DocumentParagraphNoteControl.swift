import SwiftUI
import WimmInfrastructure

public struct DocumentParagraphNoteControl: View {
    let capture: CaptureSession
    let plainText: String
    let scale: CGFloat
    let canRecord: Bool
    let target: (TextQuoteSelector) -> CommentTarget?
    let create: (String) async -> Bool
    @State private var isExpanded = false
    @State private var newNoteDraft = ""
    @State private var hovered = false
    @State private var isSaving = false
    @FocusState private var isNewNoteFocused: Bool

    public init(capture: CaptureSession, plainText: String, scale: CGFloat, canRecord: Bool = true,
                target: @escaping (TextQuoteSelector) -> CommentTarget?, create: @escaping (String) async -> Bool) {
        self.capture = capture; self.plainText = plainText; self.scale = scale
        self.canRecord = canRecord
        self.target = target; self.create = create
    }

    public var body: some View {
        content.onHover { hovered = $0 }
    }

    @ViewBuilder private var content: some View {
        if isExpanded {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "note.text.badge.plus")
                        .foregroundStyle(Color.accentColor)
                    Text("Новая заметка к абзацу")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        let selector = DocumentNoteWriter.tailSelector(of: plainText)
                        if let target = target(selector) {
                            if !capture.isRecording {
                                Task {
                                    await capture.start()
                                    capture.point(at: target)
                                }
                            } else {
                                capture.point(at: target)
                            }
                            isExpanded = false
                        }
                    } label: {
                        Label(capture.isRecording ? "Привязать к записи" : "Голосом", systemImage: "mic.fill")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canRecord || capture.isBusy)
                }

                TextField("Напишите заметку (сохранится как новая заметка в библиотеке и привяжется сюда)…", text: $newNoteDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13 * scale))
                    .lineLimit(2...8)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .focused($isNewNoteFocused)
                    .onAppear { isNewNoteFocused = true }

                HStack(spacing: 8) {
                    Button("Отмена") {
                        isExpanded = false
                        newNoteDraft = ""
                    }
                    .controlSize(.small)

                    Button("Создать заметку") {
                        let text = newNoteDraft
                        isSaving = true
                        Task {
                            defer { isSaving = false }
                            if await create(text) {
                                isExpanded = false
                                newNoteDraft = ""
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSaving || newNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .padding(.top, 2)
        } else {
            Button {
                newNoteDraft = ""
                isExpanded = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                    Text("Заметка")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(Color.primary.opacity(hovered ? 0.06 : 0), in: Capsule())
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 0.95 : 0.28)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .help("Создать новую заметку в библиотеке с привязкой к этому абзацу")
        }
    }
}
