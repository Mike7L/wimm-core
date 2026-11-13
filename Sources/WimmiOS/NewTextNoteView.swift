#if os(iOS)
import SwiftUI

struct NewTextNoteView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool
    @State private var text = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                if text.isEmpty {
                    Text(L10n.iOS.NewNote.placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(L10n.iOS.NewNote.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.cancel) {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            dismiss()
                        } else {
                            showDiscardConfirmation = true
                        }
                    }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.iOS.Recording.save) {
                        Task { await save() }
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .alert(L10n.iOS.NewNote.saveFailed, isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button(L10n.Common.ok) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .onAppear { editorFocused = true }
            .confirmationDialog(
                L10n.iOS.NewNote.discardPrompt,
                isPresented: $showDiscardConfirmation
            ) {
                Button(L10n.iOS.NewNote.discard, role: .destructive) { dismiss() }
            }
        }
        .interactiveDismissDisabled(isSaving || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.createTextNote(text)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
#endif
