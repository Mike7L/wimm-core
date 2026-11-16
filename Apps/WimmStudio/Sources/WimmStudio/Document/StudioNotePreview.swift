import AppKit
import SwiftUI
import WimmDomain
import WimmInfrastructure
import WimmDocumentUI

/// One note in three rows, each about one thing: the note (when, from where, Finder, trash),
/// its recording, and its text (which text is shown, copy, edit).
struct StudioNotePreview: View {
    let entry: StudioLibraryNote
    let onSelectBlock: (() -> Void)?
    var onSave: ((URL) -> Void)? = nil
    var onClose: (() -> Void)? = nil
    var onEditingChange: ((Bool) -> Void)? = nil
    /// Moves the note to the library trash; the button is absent without it.
    var onTrash: ((URL) async -> Bool)? = nil
    /// The note row shares the window's title bar, so it clears the window buttons.
    var inTitleBar = false
    @Environment(\.dismiss) private var dismiss
    @State private var content: StudioNoteContent?
    @State private var selectedTabID = "body"
    @State private var selectedVersionID: UUID?
    @State private var isEditing = false
    @State private var isSaving = false
    @State private var draft = ""
    @State private var error: String?
    @State private var isStale = false
    @State private var confirmsTrash = false
    @State private var isTrashing = false
    @State private var playback = StudioNotePlayback()
    private let history = NoteVersionStore()

    private var isBusy: Bool { isEditing || isSaving || isTrashing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            noteRow
            Divider()
            if let content {
                if let audio = content.audioURL {
                    StudioNoteAudioPlayer(url: audio, playback: playback)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    Divider()
                }
                textRow(content)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if isEditing {
                            TextEditor(text: $draft)
                                .font(.system(size: 16, design: .monospaced))
                                .frame(minHeight: 360)
                                .padding(8)
                                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                .disabled(isSaving)
                        } else if let tab = content.visibleTabs.first(where: { $0.id == selectedTabID }) {
                            tabContent(tab, content: content)
                                .id(tab.id)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 28)
                }
            } else if let error {
                ContentUnavailableView("Не удалось открыть заметку", systemImage: "doc.badge.ellipsis", description: Text(error))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(minWidth: 540, idealWidth: 700, maxWidth: 900, minHeight: 520, idealHeight: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(isBusy)
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
        .confirmationDialog("Переместить заметку в корзину?", isPresented: $confirmsTrash) {
            Button("В корзину", role: .destructive) { trash() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(onSelectBlock == nil
                 ? "Файлы заметки останутся в корзине библиотеки. На других устройствах заметка тоже уйдёт в корзину."
                 : "На эту заметку ссылается документ. Её файлы останутся в корзине библиотеки, на других устройствах она тоже уйдёт в корзину.")
        }
    }

    // MARK: Note row

    private var noteRow: some View {
        HStack(spacing: 10) {
            Text(entry.absoluteDate.formatted(date: .long, time: .shortened)).fontWeight(.medium)
            if let origin = content?.note.origin, !origin.isEmpty {
                Text("· \(origin)").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let onSelectBlock {
                Button("К абзацу документа") { close(); onSelectBlock() }.disabled(isBusy)
            }
            Button { NSWorkspace.shared.activateFileViewerSelecting([entry.fileURL]) } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless).help("Показать в Finder").accessibilityLabel("Показать в Finder")
            if onTrash != nil {
                Button { confirmsTrash = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("В корзину").accessibilityLabel("В корзину")
                    .disabled(isBusy)
            }
            if !inTitleBar {
                Button("Закрыть") { close() }.keyboardShortcut(.cancelAction).disabled(isBusy)
            }
        }
        .font(.callout).controlSize(.small)
        .padding(.leading, inTitleBar ? 78 : 16).padding(.trailing, 14)
        .frame(height: inTitleBar ? 28 : 40)
        .background {
            // The window's own close button is the only one there; Escape still closes.
            if inTitleBar {
                Button("") { close() }.keyboardShortcut(.cancelAction).disabled(isBusy).hidden()
            }
        }
    }

    private func trash() {
        guard let onTrash, !isBusy else { return }
        isTrashing = true; error = nil
        playback.stop()
        Task {
            if await onTrash(entry.fileURL) { close() }
            else { error = "Не удалось переместить заметку в корзину." }
            isTrashing = false
        }
    }

    // MARK: Text row

    /// Single tabs stay buttons; several texts or attachments fold into one menu named
    /// after what is shown.
    private struct Segment: Identifiable {
        let id: String
        let tabs: [StudioNoteContent.Tab]
    }

    private func segments(_ content: StudioNoteContent) -> [Segment] {
        var result: [Segment] = []
        for tab in content.visibleTabs {
            let folds = tab.group == .texts || tab.group == .attachments
            if folds, let index = result.firstIndex(where: { $0.tabs.first?.group == tab.group }) {
                result[index] = Segment(id: result[index].id, tabs: result[index].tabs + [tab])
            } else {
                result.append(Segment(id: tab.id, tabs: [tab]))
            }
        }
        return result
    }

    private func textRow(_ content: StudioNoteContent) -> some View {
        HStack(spacing: 4) {
            ViewThatFits(in: .horizontal) {
                segmentBar(content)
                ScrollView(.horizontal, showsIndicators: false) { segmentBar(content) }
            }
            Spacer(minLength: 12)
            if isEditing {
                Button("Отмена") { isEditing = false; error = nil }.disabled(isSaving)
                Button(isSaving ? "Сохраняю…" : "Сохранить") { saveDraft() }
                    .keyboardShortcut("s", modifiers: .command).disabled(isSaving)
            } else {
                if let text = selectedText(content) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Копировать текст").accessibilityLabel("Копировать текст")
                }
                if content.editsBody(tabID: selectedTabID) {
                    Button { draft = content.bodyText; error = nil; isEditing = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless).help("Править текст").accessibilityLabel("Править текст")
                    .disabled(isTrashing)
                }
            }
        }
        .controlSize(.small)
        .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 6)
    }

    private func segmentBar(_ content: StudioNoteContent) -> some View {
        HStack(spacing: 2) {
            ForEach(segments(content)) { segment in
                let isSelected = segment.tabs.contains { $0.id == selectedTabID }
                if segment.tabs.count == 1, let tab = segment.tabs.first {
                    Button { selectedTabID = tab.id } label: { segmentLabel(tab.title, isSelected: isSelected) }
                        .buttonStyle(.plain).fixedSize()
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                } else {
                    Menu {
                        ForEach(segment.tabs) { tab in
                            Button { selectedTabID = tab.id } label: {
                                if tab.id == selectedTabID { Label(tab.title, systemImage: "checkmark") }
                                else { Text(tab.title) }
                            }
                        }
                    } label: {
                        segmentLabel(menuTitle(segment, content: content), isSelected: isSelected, isMenu: true)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .disabled(isBusy)
    }

    /// The texts menu is named after the text on screen; while another section is open it
    /// names the text the note is built from.
    private func menuTitle(_ segment: Segment, content: StudioNoteContent) -> String {
        guard segment.tabs.first?.group == .texts else { return "Вложения" }
        let shown = segment.tabs.first { $0.id == selectedTabID }
            ?? segment.tabs.first { $0.id == content.bodyTwinID }
            ?? segment.tabs.first { $0.id == content.currentTextTabID }
        return (shown ?? segment.tabs[0]).title
    }

    private func segmentLabel(_ title: String, isSelected: Bool, isMenu: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            if isMenu { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.callout)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(isSelected ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    // MARK: Loading

    private func load(initial: Bool, select: String? = nil) async {
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
            let wanted = select ?? selectedTabID
            selectedTabID = loaded.visibleTabs.contains { $0.id == wanted } ? wanted : loaded.initialTabID
            return
        }
        content = loaded
        selectedTabID = loaded?.initialTabID ?? "body"
        if loaded == nil { error = "Файл заметки недоступен." }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    // MARK: Content

    @ViewBuilder
    private func tabContent(_ tab: StudioNoteContent.Tab, content: StudioNoteContent) -> some View {
        switch tab.content {
        case .body:
            formattedText(content.bodyText)
        case .text(let text, let detail):
            VStack(alignment: .leading, spacing: 16) {
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
                if content.audioURL != nil, !tab.turns.isEmpty { turnList(tab.turns) }
                else { formattedText(text) }
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

    /// Each turn's time seeks the recording; the turn being played is marked.
    private func turnList(_ turns: [StudioNoteContent.Tab.Turn]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(turns) { turn in
                let isCurrent = playback.isReady && playback.position > 0
                    && playback.position >= turn.start && playback.position < turn.end
                VStack(alignment: .leading, spacing: 3) {
                    Button { playback.seek(to: turn.start, play: true) } label: {
                        Text("\(StudioNoteAudioPlayer.time(turn.start)) · \(turn.label)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).disabled(!playback.isReady)
                    .help("Слушать с этого места").accessibilityHint("Слушать с этого места")
                    Text(turn.text).font(.system(size: 17)).lineSpacing(4)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isCurrent ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, -8)
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
        guard let tab = content.visibleTabs.first(where: { $0.id == selectedTabID }) else { return nil }
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
                _ = try await Task.detached(priority: .userInitiated) {
                    try await StudioNoteWriter.save(text, content: snapshot, history: history)
                }.value
                isEditing = false; isSaving = false
                // The edit gives the note a text of its own, next to the transcript it came from.
                await load(initial: false, select: "body")
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
