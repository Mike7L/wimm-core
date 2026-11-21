import AppKit
import SwiftUI
import WimmDocumentUI
import WimmDomain
import WimmInfrastructure

/// Studio's main window: a toolbar and the shown panels in a row. Fixed-width
/// panels are resized at the edge that faces the flexible ones.
struct StudioMainView: View {
    @Bindable var panels: StudioWindowModel
    let documentModel: DocumentModel
    let capture: CaptureSession
    let recentNotes: RecentNotes
    var cloudSync: StudioCloudSync?
    /// The private-mode switch was flipped here (the delegate plays the cue).
    var onPrivateModeChanged: @MainActor (Bool) -> Void = { _ in }

    var body: some View {
        let shown = panels.shownPanels
        HStack(spacing: 0) {
            if shown.isEmpty {
                ContentUnavailableView {
                    Label("Все панели скрыты", systemImage: "rectangle.split.3x1")
                } description: {
                    Text("Кнопки в верхней строке или ⌘1–⌘5 вернут любую.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let layout = StudioPanelLayout(shown: shown)
                ForEach(Array(shown.enumerated()), id: \.element) { index, panel in
                    if index > 0 {
                        StudioPanelSeparator(panels: panels, resizes: layout.resized(between: index - 1))
                    }
                    panelView(panel)
                        .frame(width: layout.fills(panel) ? nil : panels.width(of: panel))
                        .frame(minWidth: layout.fills(panel) ? panel.minWidth : nil,
                               maxWidth: layout.fills(panel) ? .infinity : nil)
                }
            }
        }
        .toolbar { toolbar }
        .sheet(item: $panels.openedNote) { entry in
            StudioNotePreview(entry: entry, onSelectBlock: citingBlockAction(for: entry),
                              onSave: { recentNotes.reload(changedFiles: [$0]) },
                              onTrash: { file in
                                  guard await StudioNoteTrash.move(file) else { return false }
                                  recentNotes.reload()
                                  return true
                              })
        }
        .onChange(of: documentModel.secretary.showsPanel) { _, shows in
            guard shows else { return }
            documentModel.secretary.showsPanel = false
            let model = documentModel
            SecretaryWindow.show(model.secretary, actions: SecretaryWindowActions(
                document: { model.fileURL },
                pendingThreads: { model.threads.filter { $0.status == .open }.count },
                canStart: { !model.isEditing },
                answerComments: { model.runSecretary(.comments) },
                runPass: { model.runSecretary(.pass) }))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            panels.refreshPrivateMode()
        }
    }

    @ViewBuilder
    private func panelView(_ panel: StudioPanel) -> some View {
        switch panel {
        case .timeline:
            StudioTimelineView(notes: recentNotes.allNotes, revision: recentNotes.revision,
                               document: documentModel.document,
                               revealNoteID: panels.revealNoteID,
                               onOpenNote: { panels.open($0) })
        case .document:
            StudioDocumentView(model: documentModel, capture: capture, recentNotes: recentNotes,
                               cloudSync: cloudSync, panels: panels)
        case .notes, .note, .alyona:
            ContentUnavailableView {
                Label(panel.title, systemImage: panel.systemImage)
            } description: {
                Text("Панель появится на следующих шагах переделки Studio.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                ForEach(StudioPanel.allCases) { panel in
                    Toggle(isOn: Binding(get: { panels.isVisible(panel) },
                                         set: { panels.setVisible(panel, $0) })) {
                        Label(panel.title, systemImage: panel.systemImage)
                    }
                    .help("\(panel.title) (⌘\(panel.shortcut))")
                }
            }
            .toggleStyle(.button)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if documentModel.hasSecretaryWorkspace {
                Button { documentModel.secretary.showsPanel = true } label: {
                    Label(documentModel.secretary.isRunning ? "Секретарь работает" : "Секретарь",
                          systemImage: "wand.and.sparkles")
                        .labelStyle(.titleAndIcon)
                }
                .help("Окно секретаря: проход, ответы на комментарии, история")
            }
            Toggle(isOn: Binding(get: { panels.privateMode }, set: {
                panels.setPrivateMode($0)
                onPrivateModeChanged(panels.privateMode)
            })) {
                Label(panels.privateMode ? "Приватно" : "Облако",
                      systemImage: panels.privateMode ? "lock.fill" : "lock.open")
                    .labelStyle(.titleAndIcon)
            }
            .toggleStyle(.button)
            .help(panels.privateMode ? "Приватный режим: ничего не уходит в облако" : "Включить приватный режим — ничего в облако")
            Button { capture.toggle() } label: {
                Label(capture.isRecording ? "Стоп" : "Запись",
                      systemImage: capture.isRecording ? "stop.circle.fill" : "mic.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.red)
            }
            .disabled(capture.isBusy || capture.isSending)
            .help(capture.isRecording ? "Остановить запись (⌥W)" : "Начать запись (⌥W)")
        }
    }

    private func citingBlockAction(for note: StudioLibraryNote) -> (() -> Void)? {
        guard let document = documentModel.document,
              let block = StudioTimeline.citingBlock(for: note, in: document) else { return nil }
        return { [panels] in panels.reveal(blockID: block.id) }
    }
}

/// Which panel fills the room left over, and which panel a separator resizes.
struct StudioPanelLayout: Equatable {
    let shown: [StudioPanel]

    /// The flexible panels fill; with none shown, the last panel does.
    func fills(_ panel: StudioPanel) -> Bool {
        if panel.defaultWidth == nil { return true }
        return !shown.contains { $0.defaultWidth == nil } && panel == shown.last
    }

    private var firstFilling: Int? { shown.firstIndex(where: fills) }

    /// The separator after `shown[left]`: a fixed panel left of the filling ones
    /// grows to the right, one right of them grows to the left. Nil between two
    /// filling panels.
    func resized(between left: Int) -> StudioPanelSeparator.Resize? {
        guard let flex = firstFilling, shown.indices.contains(left + 1) else { return nil }
        if left < flex, !fills(shown[left]) { return .init(panel: shown[left], sign: 1) }
        let right = left + 1
        if right > flex, !fills(shown[right]) { return .init(panel: shown[right], sign: -1) }
        return nil
    }
}

struct StudioPanelSeparator: View {
    struct Resize: Equatable {
        let panel: StudioPanel
        /// +1: dragging right widens the panel; -1: dragging left does.
        let sign: CGFloat
    }

    let panels: StudioWindowModel
    let resizes: Resize?
    @State private var startWidth: CGFloat?
    @State private var cursorPushed = false
    @State private var hovering = false

    var body: some View {
        Divider()
            .overlay {
                if let resizes {
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hovering = inside
                            updateCursor()
                        }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = startWidth ?? panels.width(of: resizes.panel) ?? resizes.panel.minWidth
                                startWidth = start
                                panels.setWidth(start + resizes.sign * value.translation.width, for: resizes.panel)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                panels.storeWidth(of: resizes.panel)
                                updateCursor()
                            })
                }
            }
            .onDisappear {
                hovering = false
                startWidth = nil
                updateCursor()
            }
    }

    /// The resize cursor stays while hovering or dragging; pushed and popped once each.
    private func updateCursor() {
        let wants = hovering || startWidth != nil
        if wants, !cursorPushed { NSCursor.resizeLeftRight.push(); cursorPushed = true }
        if !wants, cursorPushed { NSCursor.pop(); cursorPushed = false }
    }
}
