import AppKit
import SwiftUI
import WimmDomain
import WimmInfrastructure
import WimmDocumentUI

struct StudioNotePreview: View {
    let entry: StudioLibraryNote
    let onSelectBlock: (() -> Void)?
    var onSave: ((URL) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onEditingChange: ((Bool) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var content: StudioNoteContent?
    @State private var selectedTabID = "body"
    @State private var selectedVersionID: UUID?
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var draft = ""
    @State private var error: String?
    @State private var isStale = false
    private let history = NoteVersionStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Источник", systemImage: "doc.text").foregroundStyle(.secondary)
                Spacer()
                Button("Закрыть") { close() }.keyboardShortcut(.cancelAction)
                    .disabled(isEditing || isSaving)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            if let content {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header(content.note)
                        if let audio = content.audioURL { StudioNoteAudioPlayer(url: audio) }
                        tabBar(content)
                        if isEditing {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Правка текста · Markdown").font(.caption).foregroundStyle(.secondary)
                                TextEditor(text: $draft)
                                    .font(.system(size: 16, design: .monospaced))
                                    .frame(minHeight: 320)
                                    .padding(8)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                    .disabled(isSaving)
                            }
                        } else if let tab = content.tabs.first(where: { $0.id == selectedTabID }) {
                            tabContent(tab, content: content)
                                .id(tab.id)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                        }
                        DisclosureGroup("Сведения") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(content.note.fileURL.lastPathComponent)
                                if let origin = content.note.origin { Text(origin) }
                                Text("Изменено: \(content.note.fileModified.formatted(date: .abbreviated, time: .shortened))")
                            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        }.font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 24)
                }
            } else {
                if let error {
                    ContentUnavailableView("Не удалось открыть заметку", systemImage: "doc.badge.ellipsis", description: Text(error))
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            Divider()
            HStack {
                if let onSelectBlock {
                    Button("К абзацу документа") { close(); onSelectBlock() }
                        .disabled(isEditing || isSaving)
                }
                Spacer()
                Menu {
                    Button("Открыть файл") { NSWorkspace.shared.open(entry.fileURL) }
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) }
                } label: { Label("Файл", systemImage: "ellipsis") }
                .fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 540, idealWidth: 700, maxWidth: 900, minHeight: 520, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isEditing || isSaving)
        .onChange(of: isEditing || isSaving) { _, busy in
            onEditingChange?(busy)
            if !busy, isStale { Task { await load(initial: false) } }
        }
        .task(id: entry.id) { await load(initial: true) }
        // A transcript that lands while the note is open (the local run after a
        // recording) must show up without reopening it.
        .onReceive(NotificationCenter.default.publisher(for: .studioNoteChanged)) { note in
            guard let files = note.object as? [URL],
                  files.contains(where: { $0.standardizedFileURL == entry.fileURL.standardizedFileURL }) else { return }
            if isEditing || isSaving { isStale = true } else { Task { await load(initial: false) } }
        }
    }

    private func load(initial: Bool) async {
        isStale = false
        let file = entry.fileURL
        let history = history
        let loaded = await Task.detached(priority: .userInitiated) { () -> StudioNoteContent? in
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return await StudioNoteContent.load(file: file, history: history)
        }.value
        guard !Task.isCancelled else { return }
        if !initial {
            // A refresh never interrupts an edit or blanks an open note.
            guard let loaded, !isEditing, !isSaving else { isStale = loaded != nil; return }
            content = loaded
            if !loaded.tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = loaded.initialTabID }
            return
        }
        content = loaded
        selectedTabID = loaded?.initialTabID ?? "body"
        if loaded == nil { error = "Файл заметки недоступен." }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func header(_ note: Note) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(note.studioTitle).font(.system(size: 25, weight: .medium))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("\(note.absoluteDate.formatted(date: .long, time: .shortened)) · \(note.fileURL.pathExtension.uppercased())")
                    .foregroundStyle(.secondary)
                if note.refinedText == nil, let label = note.studioTranscriptLabel {
                    Text("· \(label)").foregroundStyle(note.hasFileTranscript ? Color.green : Color.orange)
                }
            }.font(.caption)
        }
    }

    private func tabBar(_ content: StudioNoteContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                tabs(content)
                ScrollView(.horizontal, showsIndicators: true) { tabs(content).padding(.bottom, 6) }
            }
            HStack {
                if selectedTabID == "body" {
                    if isEditing {
                        Button(isSaving ? "Сохраняю…" : "Сохранить") { saveDraft() }
                            .keyboardShortcut("s", modifiers: .command).disabled(isSaving)
                        Button("Отмена") { isEditing = false; error = nil }.disabled(isSaving)
                    } else {
                        Button("Править") { draft = content.bodyText; error = nil; isEditing = true }
                    }
                }
                Spacer()
                if let text = selectedText(content), !isEditing {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label("Копировать", systemImage: "doc.on.doc") }
                }
            }.controlSize(.small)
        }
    }

    private func tabs(_ content: StudioNoteContent) -> some View {
        HStack(spacing: 4) {
            ForEach(content.tabs) { tab in
                Button { selectedTabID = tab.id } label: {
                    Text(tab.title).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 7)
                        .background(selectedTabID == tab.id ? Color.primary.opacity(0.07) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).fixedSize()
                .accessibilityAddTraits(selectedTabID == tab.id ? .isSelected : [])
                .help(tab.title).disabled(isEditing || isSaving)
            }
        }
    }

    @ViewBuilder
    private func tabContent(_ tab: StudioNoteContent.Tab, content: StudioNoteContent) -> some View {
        switch tab.content {
        case .body:
            formattedText(content.bodyText)
        case .text(let text, let detail):
            VStack(alignment: .leading, spacing: 16) {
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                formattedText(text)
            }
        case .source(let url):
            StudioNoteSourceView(url: url)
        case .history:
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack {
                        ForEach(content.versions.reversed()) { version in
                            Button {
                                selectedVersionID = version.id
                            } label: {
                                Text("\(version.savedAt.formatted(date: .abbreviated, time: .shortened)) · \(versionLabel(version))")
                                    .padding(7)
                                    .background(selectedVersion(content)?.id == version.id ? Color.primary.opacity(0.07) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.bottom, 6)
                }
                Text("История текста заметки · только чтение").font(.caption).foregroundStyle(.secondary)
                if let version = selectedVersion(content) { formattedText(version.text) }
            }
        }
    }

    private func formattedText(_ text: String) -> some View {
        Group {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Текста пока нет").foregroundStyle(.secondary)
            } else {
                MarkdownTextView(content: text, baseURL: entry.fileURL.deletingLastPathComponent(), scale: 17.0 / 14)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedVersion(_ content: StudioNoteContent) -> NoteVersion? {
        content.versions.first { $0.id == selectedVersionID } ?? content.versions.last
    }

    private func versionLabel(_ version: NoteVersion) -> String {
        switch version.source {
        case .baseline: "До правки"
        case .manual: "Правка"
        case .restored: "Восстановлено"
        }
    }

    private func selectedText(_ content: StudioNoteContent) -> String? {
        guard let tab = content.tabs.first(where: { $0.id == selectedTabID }) else { return nil }
        switch tab.content {
        case .body: return content.bodyText
        case .text(let text, _): return text
        case .history: return selectedVersion(content)?.text
        case .source: return nil
        }
    }

    private func saveDraft() {
        guard let snapshot = content, !isSaving else { return }
        let text = draft
        guard text != snapshot.bodyText else { isEditing = false; return }
        isSaving = true; error = nil
        Task {
            do {
                let history = history
                let versions = try await Task.detached(priority: .userInitiated) {
                    try await StudioNoteWriter.save(text, content: snapshot, history: history)
                }.value
                content?.note.refinedText = text
                content?.expectedRefinedText = text
                content?.versions = versions
                if !versions.isEmpty, content?.tabs.contains(where: { $0.id == "history" }) == false {
                    content?.tabs.append(.init(id: "history", title: "История", content: .history))
                }
                isEditing = false
                onSave?(entry.fileURL)
            } catch { self.error = error.localizedDescription }
            isSaving = false
        }
    }
}

extension Notification.Name {
    /// Posted on the main thread with `[URL]` when notes were created or changed here.
    static let studioNoteChanged = Notification.Name("com.micha.wimm.studio.noteChanged")
}
