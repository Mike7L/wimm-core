import AppKit
import WimmDocumentUI
import SwiftUI
import WimmDomain
import WimmInfrastructure
import WimmSecretary

struct StudioDocumentNode: Identifiable {
    let block: PersonalDocument.Block
    var children: [StudioDocumentNode] = []
    var id: Int { block.id }

    static func tree(_ document: PersonalDocument) -> [StudioDocumentNode] {
        let visible = document.blocks.filter {
            if case .hidden = $0.kind { return false }
            return true
        }
        var idx = 0
        func parse(until level: Int) -> [StudioDocumentNode] {
            var nodes: [StudioDocumentNode] = []
            while idx < visible.count {
                let block = visible[idx]
                if case .heading(let next) = block.kind, next <= level { break }
                idx += 1
                var node = StudioDocumentNode(block: block)
                if case .heading(let next) = block.kind {
                    node.children = parse(until: next)
                }
                nodes.append(node)
            }
            return nodes
        }
        return parse(until: 0)
    }
}

struct StudioDocumentView: View {
    @Bindable var model: DocumentModel
    let capture: CaptureSession
    let recentNotes: RecentNotes

    @AppStorage("WimmStudio.showsTimeline") private var showsTimeline = true
    @AppStorage("WimmStudio.textScale") private var textScale = 1.0
    @AppStorage("WimmStudio.showsResolved") private var showsResolved = false
    @AppStorage("WimmStudio.showsInbox") private var showsInbox = true

    @State private var inbox = StudioInboxModel()
    @State private var expandedChangeBlocks: Set<Int> = []
    @State private var expandedQuestionBlocks: Set<Int> = []
    @State private var changedHeadings: Set<Int> = []

    @State private var speech = PersonalDocumentSpeech()
    @State private var showsReader = false
    @GestureState private var pinch: CGFloat = 1
    @State private var expanded: Set<Int> = []
    @State private var didSeedExpansion = false
    @State private var editingBlockID: Int?
    @State private var editDraft = ""
    @State private var selectedNote: StudioLibraryNote?
    @State private var timelineNoteID: UUID?
    @State private var revealBlockID: Int?
    @State private var highlightedBlockID: Int?
    @State private var focusedThreadID: String?
    @FocusState private var isEditorFocused: Bool

    private var scale: CGFloat { CGFloat(PersonalDocumentZoom.clamped(textScale * Double(pinch))) }

    var body: some View {
        HStack(spacing: 0) {
            if showsInbox, let document = model.document, model.hasSecretaryWorkspace {
                StudioInboxView(inbox: inbox, document: document, threads: model.threads,
                                onReveal: { showsReader = false; revealBlockID = $0 },
                                onRevealChange: { change in
                                    expandedChangeBlocks.insert(change.blockID)
                                    showsReader = false
                                    revealBlockID = change.blockID
                                },
                                onRevealQuestion: { number in
                                    guard let block = inbox.questionBlocks[number] else { return }
                                    expandedQuestionBlocks.insert(block)
                                    showsReader = false
                                    revealBlockID = block
                                },
                                onRevealThread: { reveal(thread: $0) },
                                onOpenSource: { openSource($0, in: document) },
                                onAnswered: { recentNotes.reload(changedFiles: [$0]) })
                .frame(width: 310)
                Divider()
            }
            mainColumn
            if showsTimeline {
                Divider()
                StudioTimelineView(notes: recentNotes.allNotes, revision: recentNotes.revision,
                                   document: model.document,
                                   revealNoteID: timelineNoteID,
                                   onOpenNote: { openNote($0) })
                .frame(width: 320)
            }
        }
        .sheet(item: $selectedNote) { entry in
            StudioNotePreview(entry: entry, onSelectBlock: citingBlockAction(for: entry),
                              onSave: { recentNotes.reload(changedFiles: [$0]) })
        }
        .onChange(of: model.secretary.showsPanel) { _, shows in
            guard shows else { return }
            model.secretary.showsPanel = false
            let model = model
            SecretaryWindow.show(model.secretary, actions: SecretaryWindowActions(
                document: { model.fileURL },
                pendingThreads: { model.threads.filter { $0.status == .open }.count },
                canStart: { !model.isEditing },
                answerComments: { model.runSecretary(.comments) },
                runPass: { model.runSecretary(.pass) }))
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let document = model.document else { return .systemAction }
            openLink(url, in: document)
            return .handled
        })
        .onDisappear { speech.stop() }
        .onChange(of: model.fileURL) { _, _ in
            speech.stop()
            didSeedExpansion = false
            inbox.clearWorkspace()
            revealBlockID = nil
            expandedChangeBlocks = []
            expandedQuestionBlocks = []
        }
        .onChange(of: showsReader) { _, open in if !open { speech.stop() } }
        .task {
            await model.load()
            updateInbox()
            if DocumentProfile.enabled { DocumentDiagnostics.control.documentLoaded = model.document != nil }
            if !didSeedExpansion, let doc = model.document {
                didSeedExpansion = true
                expanded = DocumentProfile.enabled ? [] : Set(doc.blocks.filter {
                    if case .heading(let lvl) = $0.kind { return lvl <= 2 }
                    return false
                }.map(\.id))
            }
        }
        .onChange(of: DocumentDiagnostics.control.expansion) { _, value in
            guard DocumentProfile.enabled, let doc = model.document else { return }
            expanded = value == 0 ? [] : Set(doc.blocks.map(\.id))
        }
        .task(id: model.commentsFileURL) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.reloadComments()
                inbox.reloadWorkspaceFiles()
            }
        }
        .onChange(of: model.document?.text) { _, _ in
            expandedChangeBlocks = []
            expandedQuestionBlocks = []
            updateInbox()
        }
        .onChange(of: inbox.diff) { _, _ in refreshChangedHeadings() }
        .onChange(of: inbox.seen) { _, _ in refreshChangedHeadings() }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            toolbar
            DocumentCaptureStatus(capture: capture)
            Divider()

            if let document = model.document {
                if showsReader {
                    StudioParagraphReader(speech: speech, document: document, isPresented: $showsReader)
                } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DocumentReadingLayout.blockSpacing * scale) {
                            if DocumentDiagnostics.reference {
                                ForEach(StudioDocumentNode.tree(document)) { node in nodeView(node, document: document) }
                            } else {
                            ForEach(visibleBlocks(in: document), id: \.block.id) { row in
                                nodeView(StudioDocumentNode(block: row.block), document: document)
                                    .padding(.leading, CGFloat(row.indentation) * DocumentReadingLayout.outlineIndent * scale)
                                    .padding(.top, headingSpacing(for: row.block) * scale)
                            }
                            }
                            let detached = visibleThreads(model.detached)
                            if !detached.isEmpty {
                                Divider().padding(.top, 12)
                                Text("Detached threads (\(detached.count))")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(detached) { thread in
                                    detachedThreadCard(thread)
                                }
                            }
                        }
                        .frame(maxWidth: DocumentReadingLayout.columnWidth * scale, alignment: .leading)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, DocumentReadingLayout.horizontalPadding)
                        .padding(.vertical, DocumentReadingLayout.verticalPadding)
                    }
                    .simultaneousGesture(MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { textScale = PersonalDocumentZoom.clamped(textScale * Double($0.magnification)) })
                    .onChange(of: speech.speakingBlockID) { _, id in
                        guard let id else { return }
                        reveal(blockID: id, in: document, proxy: proxy)
                    }
                    .onChange(of: DocumentDiagnostics.control.scrollToEnd) { _, value in
                        if DocumentProfile.enabled, value, let id = document.blocks.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onChange(of: revealBlockID, initial: true) { _, id in
                        guard let id else { return }
                        revealBlockID = nil
                        reveal(blockID: id, in: document, proxy: proxy)
                    }
                }
                }
            } else if model.fileURL == nil {
                ContentUnavailableView {
                    Label("Personal Document", systemImage: "doc.text")
                } description: {
                    Text("Open a structured Markdown document (e.g. me_structured.md).")
                } actions: {
                    Button("Choose Document…") { model.choose() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                if model.errorMessage == nil {
                    ProgressView()
                }
                Spacer()
            }

            if let err = model.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.callout)
                    Spacer()
                    Button("Reload") { Task { await model.load() } }
                }
                .padding(12)
                .background(Color.red.opacity(0.08))
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                showsTimeline.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless)
            .help("Toggle library timeline")

            if model.hasSecretaryWorkspace {
                Button {
                    showsInbox.toggle()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "tray")
                        if inbox.badgeCount > 0 {
                            Text("\(inbox.badgeCount)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        }
                    }
                }
                .buttonStyle(.borderless)
                .help("Что нового: правки секретаря, вопросы, ответы, проходы (⌘⇧I)")
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            Text(model.fileURL?.lastPathComponent ?? "Personal Document")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 4) {
                Button { textScale = PersonalDocumentZoom.zoomedOut(textScale) } label: { Image(systemName: "minus") }
                    .keyboardShortcut("-", modifiers: .command)
                Button("\(Int((scale * 100).rounded()))%") { textScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                    .monospacedDigit()
                    .frame(minWidth: 42)
                Button { textScale = PersonalDocumentZoom.zoomedIn(textScale) } label: { Image(systemName: "plus") }
                    .keyboardShortcut("+", modifiers: .command)
            }
            .buttonStyle(.borderless)

            if model.document != nil {
                Button {
                    showsReader.toggle()
                } label: {
                    Image(systemName: showsReader ? "book.fill" : "book.closed")
                }
                .buttonStyle(.borderless)
                .help("Читалка по абзацам: скорость и перемотка")
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            if let document = model.document, !showsReader {
                Button {
                    if speech.isSpeaking { speech.stop() } else { speech.startFromBeginning(in: document) }
                } label: { Image(systemName: speech.isSpeaking ? "stop.fill" : "speaker.wave.2") }
                .buttonStyle(.borderless).help("Читать документ вслух / остановить")
            }
            if model.hasSecretaryWorkspace {
                Menu {
                    Button("Полный проход") { model.secretary.showsPanel = true; model.runSecretary(.pass) }
                        .disabled(model.secretary.isRunning || editingBlockID != nil)
                    Button("Ответить на комментарии") { model.secretary.showsPanel = true; model.runSecretary(.comments) }
                        .disabled(model.secretary.isRunning || editingBlockID != nil)
                    Button("Открыть панель") { model.secretary.showsPanel = true }
                } label: {
                    Image(systemName: "wand.and.sparkles")
                } primaryAction: { model.secretary.showsPanel = true }
                .menuStyle(.borderlessButton).fixedSize()
            }
            commentsMenu

            Menu {
                Button("Choose Markdown File…") { model.choose() }.disabled(model.secretary.isRunning || editingBlockID != nil)
                Button("Reload") { Task { await model.load() } }
                if let url = model.fileURL {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: DocumentReadingLayout.toolbarHeight)
    }

    private var commentsMenu: some View {
        let open = model.threads.filter { !$0.status.isClosed }
        return Menu {
            if open.isEmpty {
                Text("No open threads")
            }
            ForEach(open) { thread in
                let label = (thread.root.reaction ?? "💬") + " " + String((thread.root.text ?? thread.root.quote ?? "").prefix(44))
                Button(label) { reveal(thread: thread) }
            }
            Divider()
            Toggle("Show resolved", isOn: $showsResolved)
            if let url = model.commentsFileURL {
                Button("Reveal threads.jsonl") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } label: {
            Label("\(open.count)", systemImage: "text.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func updateInbox() {
        guard let document = model.document, let url = model.fileURL, model.hasSecretaryWorkspace else { return }
        inbox.update(document: document, url: url)
    }

    private func refreshChangedHeadings() {
        guard let document = model.document else { changedHeadings = []; return }
        changedHeadings = inbox.headingsWithChanges(in: document)
    }

    private func reveal(thread: DocumentCommentThread) {
        if let blockID = model.threadsByBlock.first(where: { $0.value.contains { $0.id == thread.id } })?.key {
            revealBlockID = blockID
        }
        focusThread(thread.id)
    }

    private func openSource(_ id: String, in document: PersonalDocument) {
        guard let documentURL = model.fileURL else { return }
        let base = documentURL.deletingLastPathComponent()
        Task { @MainActor in
            await recentNotes.waitUntilLoaded()
            guard model.fileURL == documentURL else { return }
            if let target = document.references[id],
               let url = URL(string: target, relativeTo: base)?.absoluteURL,
               let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath) {
                openNote(note)
                return
            }

            let target = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data = try? SecretaryContext.registry(document: documentURL, references: [id], limit: 1),
                      let result = try? JSONDecoder().decode(InboxSourceLookup.self, from: data) else { return nil }
                return result.sources.first { $0.source_id == id }?.path
            }.value
            guard model.fileURL == documentURL else { return }
            if let target, let url = URL(string: target, relativeTo: base)?.absoluteURL,
               let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath)
                    ?? recentNotes.notesByMetadataName[url.lastPathComponent] {
                openNote(note)
            } else {
                inbox.errorMessage = "Запись \(id) не найдена в библиотеке."
            }
        }
    }

    private struct InboxSourceLookup: Decodable {
        struct Source: Decodable {
            let source_id: String
            let path: String
        }

        let sources: [Source]
    }

    private func headingSpacing(for block: PersonalDocument.Block) -> CGFloat {
        guard case .heading(let level) = block.kind else { return 0 }
        return DocumentReadingLayout.headingSpacing(level)
    }

    private func visibleBlocks(in document: PersonalDocument) -> [(block: PersonalDocument.Block, indentation: Int)] {
        let levels: [Int?] = document.blocks.map {
            switch $0.kind {
            case .heading(let level): return level
            case .hidden: return -1
            case .body: return nil
            }
        }
        let indentation = DocumentOutline.indentationLevels(levels: levels)
        return DocumentOutline.visibleIndices(levels: levels, expanded: expanded, ids: document.blocks.map(\.id))
            .map { (block: document.blocks[$0], indentation: indentation[$0]) }
    }

    private func nodeView(_ node: StudioDocumentNode, document: PersonalDocument) -> AnyView {
        if case .heading(let level) = node.block.kind {
            if level == 1 {
                return AnyView(
                    VStack(alignment: .leading, spacing: 20) {
                        blockView(node.block, document: document)
                        ForEach(node.children) { child in
                            nodeView(child, document: document)
                        }
                    }
                    .id(node.id)
                )
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expanded.contains(node.id) },
                                set: { if $0 { expanded.insert(node.id) } else { expanded.remove(node.id) } }
                            )
                        ) {
                            if !node.children.isEmpty {
                                VStack(alignment: .leading, spacing: 16) {
                                    ForEach(node.children) { child in
                                        nodeView(child, document: document)
                                    }
                                }
                                .padding(.top, 14)
                            }
                            if editingBlockID == node.id { blockView(node.block, document: document) }
                        } label: {
                            HStack(spacing: 6) {
                                Text(headingTitle(node.block))
                                    .font(.system(size: DocumentReadingLayout.headingSize(level) * scale, weight: level <= 2 ? .bold : .semibold))
                                if changedHeadings.contains(node.id) {
                                    Circle().fill(Color.orange).frame(width: 7, height: 7)
                                        .help("Здесь есть непрочитанные правки")
                                }
                            }
                            .contextMenu {
                                Button("Читать отсюда") { speech.toggle(blockID: node.id, in: document) }
                                Button("Edit Heading…") { startEditing(node.block) }
                            }
                        }
                        changeMarker(for: node.id)
                    }
                    changeDetails(for: node.id)
                }
                .id(node.id)
            )
        }
        if node.block.markdown.hasPrefix("**Редакция:") {
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        DisclosureGroup("О документе") {
                            blockView(node.block, document: document, showsChange: false).padding(.top, 10)
                        }.font(.callout).foregroundStyle(.secondary)
                        changeMarker(for: node.id)
                    }
                    changeDetails(for: node.id)
                }
                .id(node.id)
            )
        }
        return AnyView(blockView(node.block, document: document).id(node.id))
    }

    @ViewBuilder
    private func blockView(_ block: PersonalDocument.Block, document: PersonalDocument, showsChange: Bool = true) -> some View {
        if editingBlockID == block.id {
            VStack(alignment: .trailing, spacing: 8) {
                TextEditor(text: $editDraft)
                    .font(.system(size: 14 * scale, design: .monospaced))
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .focused($isEditorFocused)
                    .onAppear { isEditorFocused = true }
                HStack(spacing: 8) {
                    Button("Cancel") { editingBlockID = nil; model.isEditing = false }
                        .controlSize(.small)
                    Button("Save") {
                        let draft = editDraft
                        Task {
                            if await model.replace(block, with: draft) {
                                editingBlockID = nil
                                model.isEditing = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        } else {
            let blockThreads = visibleThreads(model.threadsByBlock[block.id] ?? [])
            let displayMD = document.displayMarkdown(for: block)
            let style = BlockRenderer.Style(scale: scale)
            let attributed = BlockRenderer.render(displayMD, baseURL: model.fileURL?.deletingLastPathComponent(), style: style)
            let placed = resolveMarks(for: blockThreads, in: attributed.string)
            let voiceRange: NSRange? = {
                guard let listening = capture.listeningAnchor,
                      listening.target.documentURL == model.fileURL else { return nil }
                return listening.target.selector.resolve(in: attributed.string)
            }()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Group {
                    if let url = DocumentMediaGallery.inlineImageURL(displayMD, baseURL: model.fileURL?.deletingLastPathComponent()) {
                        if let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath) {
                            DocumentMediaGallery(urls: [url], scale: scale, onOpen: { _ in openNote(note) })
                        } else {
                            DocumentMediaGallery(urls: [url], scale: scale)
                        }
                    } else if PersonalDocumentRendering.attributed(displayMD, baseURL: model.fileURL?.deletingLastPathComponent(), style: .init(scale: scale)) == nil {
                        MarkdownTextView(content: displayMD, baseURL: model.fileURL?.deletingLastPathComponent(), allowsTextSelection: false, scale: scale)
                            .contextMenu { Button("Редактировать") { startEditing(block) } }
                    } else {
                    StudioBlockTextView(
                        text: attributed,
                        marks: placed.marks,
                        activeVoiceRange: voiceRange,
                        actions: .init(
                            isRecording: capture.isRecording,
                            onPointVoice: { selector in
                                if let target = model.target(for: block, selector: selector) {
                                    capture.point(at: target)
                                }
                            },
                            onReact: { selector, emoji in
                                guard let target = model.target(for: block, selector: selector) else { return }
                                Task { await model.add(target, text: nil, reaction: emoji) }
                            },
                            onComment: { selector, text in
                                guard let target = model.target(for: block, selector: selector) else { return }
                                Task { await model.add(target, text: text, reaction: nil) }
                            },
                            onReply: { thread, text in
                                Task { await model.reply(to: thread, text: text) }
                            },
                            onSetStatus: { thread, status in
                                Task { await model.setStatus(status, of: thread) }
                            },
                            onEditBlock: { startEditing(block) },
                            onOpenURL: { url in openLink(url, in: document) }
                        )
                    )
                    }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity((highlightedBlockID == block.id || speech.speakingBlockID == block.id) ? 0.16 : 0))
                            .padding(-6)
                    )

                    VStack(alignment: .center, spacing: 6) {
                        if showsChange { changeMarker(for: block.id) }
                        if !(inbox.questionsByBlock[block.id] ?? []).isEmpty {
                            Button {
                                if !expandedQuestionBlocks.insert(block.id).inserted {
                                    expandedQuestionBlocks.remove(block.id)
                                }
                            } label: {
                                Text("❓")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(expandedQuestionBlocks.contains(block.id) ? "Свернуть вопросы" : "Показать вопросы")
                            .help("Вопросы секретаря к абзацу")
                        }
                        if PersonalDocumentSpeech.spokenText(for: block, in: document) != nil {
                            Button { speech.toggle(blockID: block.id, in: document) } label: {
                                Image(systemName: speech.speakingBlockID == block.id ? "stop.fill" : "speaker.wave.2")
                            }.buttonStyle(.borderless).foregroundStyle(.secondary).help("Читать отсюда / остановить")
                        }
                        let sources = document.sources(in: block)
                        if !sources.isEmpty {
                            Menu {
                                ForEach(sources, id: \.id) { source in
                                    let name = (source.target as NSString).lastPathComponent
                                    let note = recentNotes.notesByMetadataName[name]
                                    let label = note.map { "\(source.id) · \($0.studioTitle)" } ?? source.id
                                    Button(label) {
                                        if let note {
                                            openNote(note)
                                        } else if let base = model.fileURL?.deletingLastPathComponent(),
                                           let url = URL(string: source.target, relativeTo: base)?.absoluteURL {
                                            openLink(url, in: document)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Cited sources")
                        }
                    }
                }

                if showsChange { changeDetails(for: block.id) }

                if expandedQuestionBlocks.contains(block.id) {
                    ForEach(inbox.questionsByBlock[block.id] ?? []) { question in
                        StudioQuestionCard(inbox: inbox, question: question, inline: true,
                                           onOpenSource: { openSource($0, in: document) },
                                           onAnswered: { url in
                                               if inbox.questionsByBlock[block.id] == nil {
                                                   expandedQuestionBlocks.remove(block.id)
                                               }
                                               recentNotes.reload(changedFiles: [url])
                                           })
                    }
                }

                ForEach(placed.unplaced) { thread in
                    detachedThreadCard(thread)
                        .padding(.leading, 12)
                }

                StudioCitedImages(sourceNames: document.sources(in: block).map { ($0.target as NSString).lastPathComponent },
                                  notesByMetadataName: recentNotes.notesByMetadataName, revision: recentNotes.revision,
                                  scale: scale, onOpenNote: { openNote($0) })
                if case .body = block.kind {
                    afterParagraphNoteControl(block: block, plainText: attributed.string)
                }
            }
        }
    }

    @ViewBuilder
    private func changeMarker(for blockID: Int) -> some View {
        if inbox.changesByBlock[blockID] != nil {
            Button {
                if !expandedChangeBlocks.insert(blockID).inserted { expandedChangeBlocks.remove(blockID) }
            } label: {
                Text("📝")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expandedChangeBlocks.contains(blockID) ? "Свернуть правку" : "Показать правку")
            .help("Непрочитанная правка")
        }
    }

    @ViewBuilder
    private func changeDetails(for blockID: Int) -> some View {
        if expandedChangeBlocks.contains(blockID), let change = inbox.changesByBlock[blockID] {
            StudioChangeCard(change: change) {
                inbox.markSeen(change)
                expandedChangeBlocks.remove(blockID)
            }
        }
    }

    private func citingBlockAction(for note: StudioLibraryNote) -> (() -> Void)? {
        guard let document = model.document,
              let block = StudioTimeline.citingBlock(for: note, in: document) else { return nil }
        return { revealBlockID = block.id }
    }

    private func afterParagraphNoteControl(block: PersonalDocument.Block, plainText: String) -> some View {
        DocumentParagraphNoteControl(capture: capture, plainText: plainText, scale: scale,
            target: { model.target(for: block, selector: $0) },
            create: { await model.createNote(after: block, text: $0, plainBlockText: plainText) != nil })
    }

    private func detachedThreadCard(_ thread: DocumentCommentThread) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(thread.root.reaction ?? "💬")
            VStack(alignment: .leading, spacing: 3) {
                if let quote = thread.root.quote, !quote.isEmpty {
                    Text("“\(quote)”").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let text = thread.root.text, !text.isEmpty {
                    Text(text).font(.system(size: 12))
                }
                if let via = thread.root.via, let url = StudioNoteLink.referenceURL(via), let document = model.document {
                    Button("Открыть заметку") { openLink(url, in: document) }.controlSize(.small)
                }
            }
            Spacer()
            Button("Resolve") {
                Task { await model.setStatus(.resolved, of: thread) }
            }
            .controlSize(.mini)
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func startEditing(_ block: PersonalDocument.Block) {
        guard !model.secretary.isRunning else { model.errorMessage = "Секретарь редактирует документ."; return }
        editDraft = block.markdown
        editingBlockID = block.id
        model.isEditing = true
    }

    private func visibleThreads(_ list: [DocumentCommentThread]) -> [DocumentCommentThread] {
        showsResolved ? list : list.filter { !$0.status.isClosed }
    }

    private func resolveMarks(for threads: [DocumentCommentThread], in text: String)
        -> (marks: [StudioBlockTextView.Mark], unplaced: [DocumentCommentThread]) {
        var marks: [StudioBlockTextView.Mark] = []
        var unplaced: [DocumentCommentThread] = []
        for thread in threads {
            if let range = thread.selector.resolve(in: text) {
                marks.append(.init(thread: thread, range: range, isFocused: focusedThreadID == thread.id))
            } else {
                unplaced.append(thread)
            }
        }
        return (marks, unplaced)
    }

    private func headingTitle(_ block: PersonalDocument.Block) -> String {
        block.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "#" })
            .trimmingCharacters(in: .whitespaces)
    }

    private func reveal(blockID: Int, in document: PersonalDocument, proxy: ScrollViewProxy) {
        // Only the headings that enclose the target: opening every heading above
        // it turned the outline into the whole 400 KB document at once.
        expanded.formUnion(StudioInbox.ancestorHeadings(of: [blockID], in: document))
        highlightedBlockID = blockID
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(blockID, anchor: .center)
            try? await Task.sleep(for: .milliseconds(150))
            proxy.scrollTo(blockID, anchor: .center)
            try? await Task.sleep(for: .seconds(2))
            if highlightedBlockID == blockID {
                withAnimation(.easeOut(duration: 0.4)) { highlightedBlockID = nil }
            }
        }
    }

    private func focusThread(_ id: String) {
        focusedThreadID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if focusedThreadID == id { focusedThreadID = nil }
        }
    }

    private func openLink(_ url: URL, in document: PersonalDocument) {
        if url.isFileURL, url.path == model.fileURL?.path, let fragment = url.fragment,
           let target = document.blocks.first(where: { $0.anchor == fragment }) {
            revealBlockID = target.id
            return
        }
        if let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath) {
            openNote(note)
        } else if url.isFileURL {
            Task { @MainActor in
                await recentNotes.waitUntilLoaded()
                if let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath) {
                    openNote(note)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func openNote(_ note: StudioLibraryNote) {
        timelineNoteID = nil
        Task { @MainActor in
            await Task.yield()
            timelineNoteID = note.id
        }
        selectedNote = note
    }
}
