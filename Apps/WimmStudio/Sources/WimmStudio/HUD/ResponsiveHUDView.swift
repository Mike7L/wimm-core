import AppKit
import SwiftUI
import WimmDocumentUI
import WimmDomain

/// Pure responsive layout rules for the single-form HUD, testable at any (W, H).
struct ResponsiveHUDLayout: Equatable {
    static let barHeight: CGFloat = 38
    static let timerMinWidth: CGFloat = 135
    static let sendMinWidth: CGFloat = 160
    static let actionsMinWidth: CGFloat = 250
    static let captionsMinWidth: CGFloat = 330
    static let textMinWidth: CGFloat = 480
    static let listFadeSpan: CGFloat = 24

    let width: CGFloat
    let height: CGFloat

    var controlBarHeight: CGFloat { min(height, Self.barHeight) }
    var listHeight: CGFloat { max(0, height - Self.barHeight) }
    var listOpacity: Double { Double(min(1, max(0, (listHeight - 6) / Self.listFadeSpan))) }
    var showsTimer: Bool { width >= Self.timerMinWidth }
    var showsSend: Bool { width >= Self.sendMinWidth }
    var showsLeadingActions: Bool { width >= Self.actionsMinWidth }
    var showsCaptions: Bool { false }
    /// The stream is readable above the bar; the bar then repeats none of it.
    var showsList: Bool { listHeight >= 24 }
    var showsStatusText: Bool { width >= Self.textMinWidth && !showsList }
}

/// One window, one view tree, continuous 2D size:
/// - Bottom control bar (38pt) is always pinned at the bottom and sheds/reveals
///   elements smoothly as `width` changes (down to just the mic switch at 76pt).
/// - Stream list occupies `max(0, height - 38)` above the bar and never leaves
///   the SwiftUI hierarchy, so resizing to a bar/pill and back never resets
///   scroll state or view identity.
struct ResponsiveHUDView: View {
    let capture: CaptureSession
    let recentNotes: RecentNotes
    let onOpenDocument: () -> Void
    var onOpenNote: (URL) -> Void = { _ in }
    var onOpenWeb: (() -> Void)?
    var island: HUDIslandModel?
    var vik: VikAssistant?
    var onSaveQuickNote: (@MainActor (@escaping @MainActor () async throws -> [URL]) -> Void)?

    @State private var clockNow = Date()
    @State private var hoveredNoteID: UUID?
    @State private var expandedVikRequest: String?
    /// False once the user scrolls up; new text then stays put until they
    /// scroll back to the end or start a recording.
    @State private var followsTail = true

    private static let bottomAnchorID = "hud-stream-bottom"
    private static let vikReplyID = "hud-vik-reply"

    init(
        capture: CaptureSession,
        recentNotes: RecentNotes,
        onOpenDocument: @escaping () -> Void,
        onOpenNote: @escaping (URL) -> Void = { _ in },
        onOpenWeb: (() -> Void)? = nil,
        island: HUDIslandModel? = nil,
        vik: VikAssistant? = nil,
        onSaveQuickNote: (@MainActor (@escaping @MainActor () async throws -> [URL]) -> Void)? = nil
    ) {
        self.capture = capture
        self.recentNotes = recentNotes
        self.onOpenDocument = onOpenDocument
        self.onOpenNote = onOpenNote
        self.onOpenWeb = onOpenWeb
        self.island = island
        self.vik = vik
        self.onSaveQuickNote = onSaveQuickNote
        island?.onTapPill = { [capture] in capture.toggle() }
    }

    /// When the island is attached to the top screen edge, the control bar sits
    /// at the top of the panel so the record switch stays right where the pill was.
    var placesControlBarAtTop: Bool {
        island?.isEnabled == true && island?.edge == .top
    }

    var body: some View {
        ZStack {
            mainContent
                .opacity(island?.showsPill == true ? 0 : 1)
                .allowsHitTesting(island?.showsPill != true)
            if let island, island.showsPill {
                islandPill(island)
            }
        }
        .background(Color.black.opacity(0.42), in: hudShape)
        .background(.ultraThinMaterial, in: hudShape)
        .clipShape(hudShape)
        .overlay(borderOverlay)
        .overlay(alignment: placesControlBarAtTop ? .bottom : .top) {
            if island?.showsPill != true {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 26, height: 3)
                    .padding(placesControlBarAtTop ? .bottom : .top, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .focusEffectDisabled()
        .preferredColorScheme(.dark)
        .task(id: capture.isRecording) {
            guard capture.isRecording else { return }
            clockNow = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                clockNow = Date()
            }
        }
    }

    /// Island forms are attached to a screen edge: square on that side,
    /// rounded on the free side (like the notch). Plain HUD keeps its rounded rectangle.
    private var hudShape: AnyShape {
        guard let island, island.isEnabled else { return AnyShape(RoundedRectangle(cornerRadius: 9)) }
        let r: CGFloat = island.isExpanded ? 14 : HUDIslandGeometry.thickness / 2
        let radii: RectangleCornerRadii
        switch island.edge {
        case .top: radii = .init(topLeading: 0, bottomLeading: r, bottomTrailing: r, topTrailing: 0)
        case .bottom: radii = .init(topLeading: r, bottomLeading: 0, bottomTrailing: 0, topTrailing: r)
        case .left: radii = .init(topLeading: 0, bottomLeading: 0, bottomTrailing: r, topTrailing: r)
        case .right: radii = .init(topLeading: r, bottomLeading: r, bottomTrailing: 0, topTrailing: 0)
        }
        return AnyShape(UnevenRoundedRectangle(cornerRadii: radii))
    }

    /// Collapsed island: near-black capsule with a quiet mic glyph; while
    /// recording a pulsing red dot (and the timer on top/bottom edges).
    /// Clicks and hover are handled by the panel.
    private func islandPill(_ island: HUDIslandModel) -> some View {
        let pulse = Int(clockNow.timeIntervalSinceReferenceDate) % 2 == 0
        return HStack(spacing: 5) {
            if vik?.isResponding == true {
                Image(systemName: "waveform").font(.system(size: 9, weight: .semibold))
                if island.edge.isHorizontal { Text("Алёна").font(.system(size: 10, weight: .medium)) }
            } else if capture.isRecording {
                Circle()
                    .fill(Color.red.opacity(pulse ? 1 : 0.55))
                    .frame(width: 6, height: 6)
                    .animation(.easeInOut(duration: 0.4), value: pulse)
                if island.edge.isHorizontal, let started = capture.startedAt {
                    Text(elapsedString(since: started, now: clockNow))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Expand HUD island")
    }

    private var mainContent: some View {
        GeometryReader { geo in
            let layout = ResponsiveHUDLayout(width: geo.size.width, height: geo.size.height)
            VStack(spacing: 0) {
                if placesControlBarAtTop {
                    controlBar(layout: layout)
                        .frame(maxWidth: .infinity, minHeight: layout.controlBarHeight, maxHeight: layout.controlBarHeight)
                }

                streamList
                    .frame(maxWidth: .infinity, minHeight: layout.listHeight, maxHeight: layout.listHeight)
                    .clipped()
                    .opacity(layout.listOpacity)
                    .allowsHitTesting(layout.showsList)
                    .overlay(alignment: .topTrailing) {
                        if let island, collapsesFromListCorner(layout) {
                            StudioBarButton(icon: "chevron.up.chevron.down",
                                            help: "Collapse to the screen edge") {
                                island.onToggle()
                            }
                            .background(Color.black.opacity(0.35), in: Circle())
                            .padding(.top, 7)
                            .padding(.trailing, 7)
                        }
                    }

                if !placesControlBarAtTop {
                    controlBar(layout: layout)
                        .frame(maxWidth: .infinity, minHeight: layout.controlBarHeight, maxHeight: layout.controlBarHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Stream List (always in the view hierarchy)

    private var showsVikReply: Bool {
        guard let vik else { return false }
        return !vik.request.isEmpty || vik.phase == .listening || vik.phase == .failed
    }

    /// With the stream open the collapse control sits in its top-right corner,
    /// away from the capture controls; a bare bar keeps it in the bar.
    private func collapsesFromListCorner(_ layout: ResponsiveHUDLayout) -> Bool {
        island?.isEnabled == true && layout.showsList && !placesControlBarAtTop
    }

    private enum VikPlacement: Equatable { case hidden, afterNote(UUID), afterNotes, afterLive }

    private var vikSourceNote: Note? {
        guard let path = vik?.replySource?.standardizedFileURL.path else { return nil }
        return recentNotes.notes.last { $0.fileURL.standardizedFileURL.path == path }
    }

    /// One rule: Vik's reply follows the note it was asked in. While that
    /// note is still the live one, that is right under the live row.
    private var vikPlacement: VikPlacement {
        guard let vik, showsVikReply else { return .hidden }
        if vik.phase == .listening { return .afterLive }
        if capture.isRecording, let source = vik.replySource, source == capture.recordingURL { return .afterLive }
        if let note = vikSourceNote { return .afterNote(note.id) }
        return .afterNotes
    }

    private var streamList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if recentNotes.notes.isEmpty && !capture.isRecording && capture.anchors.isEmpty && !showsVikReply {
                        Text(recentNotes.isLoading ? "Loading library…" : "No recent notes")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 16)
                    }

                    let placement = vikPlacement
                    ForEach(recentNotes.notes) { note in
                        noteRow(note)
                            .id(note.id)
                        if let vik, placement == .afterNote(note.id) {
                            vikReply(vik).id(Self.vikReplyID)
                        }
                    }

                    if let vik, placement == .afterNotes {
                        vikReply(vik).id(Self.vikReplyID)
                    }

                    ForEach(capture.anchors) { anchor in
                        anchorRow(anchor)
                            .id(anchor.id)
                    }

                    if capture.isRecording {
                        liveTranscriptRow
                    }

                    if let vik, placement == .afterLive {
                        vikReply(vik).id(Self.vikReplyID)
                    }

                    if let error = capture.errorMessage, !capture.isRecording {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 10)
                    Color.black
                }
            )
            .modifier(TailFollowTracker(followsTail: $followsTail))
            .onChange(of: recentNotes.notes.count) { _, _ in
                followTail(proxy)
            }
            .onChange(of: capture.isRecording) { _, _ in
                followsTail = true
                scrollToBottom(proxy)
            }
            .onChange(of: capture.anchors.count) { _, _ in
                followTail(proxy)
            }
            .onChange(of: capture.liveText) { _, _ in
                followTail(proxy)
            }
            .onChange(of: vik?.answer) { _, _ in if followsTail { scrollToVik(proxy) } }
            .onChange(of: vik?.phase) { _, _ in if followsTail { scrollToVik(proxy) } }
            .onAppear {
                scrollToBottom(proxy)
            }
        }
    }

    /// A reply that sits mid-stream is followed itself, not the tail.
    private func scrollToVik(_ proxy: ScrollViewProxy) {
        guard case .afterNote = vikPlacement, vik?.isResponding == true else { return scrollToBottom(proxy) }
        proxy.scrollTo(Self.vikReplyID, anchor: .bottom)
    }

    private func followTail(_ proxy: ScrollViewProxy) {
        if followsTail { scrollToBottom(proxy) }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
        }
    }

    private func noteRow(_ note: Note) -> some View {
        let isHovered = hoveredNoteID == note.id
        return HStack(alignment: .top, spacing: 7) {
            Button { onOpenNote(note.fileURL) } label: {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: note.studioKindIcon)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .padding(.top, 3)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.studioTitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.88))
                            .lineLimit(2)

                        HStack(spacing: 5) {
                            Text(note.absoluteDate.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if let label = note.studioTranscriptLabel {
                                Text(label)
                                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(note.hasFileTranscript ? Color.green.opacity(0.9) : Color.orange.opacity(0.9))
                            }
                        }
                    }

                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(island?.showsPill == true ? "" : "Открыть заметку")
            .accessibilityLabel("Открыть заметку: \(note.studioTitle)")

            if isHovered {
                HStack(spacing: 4) {
                    Button {
                        copyText(note.refinedText ?? note.text)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Copy note text")

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([note.fileURL])
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .help("Reveal in Finder")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(isHovered ? 0.12 : 0.05))
        )
        .onHover { inside in
            hoveredNoteID = inside ? note.id : (hoveredNoteID == note.id ? nil : hoveredNoteID)
        }
        .contextMenu {
            Button("Открыть заметку") { onOpenNote(note.fileURL) }
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.fileURL]) }
        }
    }

    private func vikIsCollapsed(_ vik: VikAssistant) -> Bool {
        guard vik.phase == .idle, !vik.answer.isEmpty, expandedVikRequest != vik.request,
              let source = vikSourceNote else { return false }
        return recentNotes.notes.last?.id != source.id
    }

    private func vikReply(_ vik: VikAssistant) -> some View {
        let source = vikSourceNote
        let finished = vik.phase == .idle && !vik.answer.isEmpty
        let collapsed = vikIsCollapsed(vik)
        let title = source.map { "Алёна · \($0.absoluteDate.formatted(.dateTime.hour().minute()))" } ?? "Алёна"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .accessibilityHidden(true)
                Text(finished ? title : vik.status)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if vik.phase == .listening, !vik.request.isEmpty {
                    Button { vik.sendNow() } label: { Image(systemName: "paperplane.fill") }
                        .help("Отправить запрос Алёне")
                }
                if vik.isResponding || vik.phase == .listening {
                    Button { vik.cancel() } label: { Image(systemName: "stop.circle") }
                        .help("Остановить Алёну")
                } else {
                    if finished {
                        Button { copyText(vik.answer) } label: { Image(systemName: "doc.on.doc") }
                            .help("Скопировать ответ")
                    }
                    if let url = vik.savedReply {
                        Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                            .help("Открыть сохранённый ответ")
                    }
                    Button { vik.dismiss() } label: { Image(systemName: "xmark") }
                        .help("Убрать ответ из ленты")
                }
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            if source == nil, vik.phase != .listening, !vik.request.isEmpty {
                Text("Ты: \(vik.request)").foregroundStyle(.secondary)
            }
            if !vik.answer.isEmpty {
                Text(VikReplyText.attributed(vik.answer, noteLabel: vikNoteLabel))
                    .lineLimit(collapsed ? 2 : nil)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        openVikReference(url)
                        return .handled
                    })
            }
            if collapsed {
                Button("Показать целиком") { expandedVikRequest = vik.request }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            if let error = vik.errorMessage {
                Text(error).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .buttonStyle(.plain)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
        .padding(.leading, source == nil ? 0 : 16)
    }

    private func vikNote(id: String) -> Note? {
        recentNotes.notes.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
    }

    private func vikNoteLabel(_ id: String) -> String? {
        vikNote(id: id).map { "заметка \($0.absoluteDate.formatted(.dateTime.hour().minute()))" }
    }

    private func openVikReference(_ url: URL) {
        guard url.scheme == VikReplyText.scheme else { return }
        if url.host == "note" {
            if let note = vikNote(id: url.lastPathComponent) { onOpenNote(note.fileURL) }
        } else {
            onOpenDocument()
        }
    }

    private func anchorRow(_ anchor: VoiceAnchor) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: anchorIcon(anchor.state))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(anchorColor(anchor.state))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text("“\(anchor.target.selector.quote)”")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(anchorLabel(anchor.state))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(anchor.state == .listening ? 0.18 : 0.08))
        )
    }

    private var liveTranscriptRow: some View {
        Button {
            if let file = savedTranscriptURL { onOpenNote(file) }
        } label: {
            liveTranscriptContent
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(savedTranscriptURL == nil)
        .help(savedTranscriptURL == nil || island?.showsPill == true ? "" : "Открыть заметку")
        .accessibilityLabel("Открыть последнюю запись")
    }

    private var savedTranscriptURL: URL? {
        guard capture.phase == .idle, !capture.liveText.isEmpty else { return nil }
        return capture.recordingURL
    }

    private var headlineNoteURL: URL? {
        guard capture.errorMessage == nil, capture.phase == .idle else { return nil }
        if !capture.liveText.isEmpty { return savedTranscriptURL }
        return recentNotes.notes.last?.fileURL
    }

    private var liveTranscriptContent: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(capture.isRecording ? Color.red : Color.green)
                .frame(width: 7, height: 7)
                .padding(.top, 4)

            Text(capture.liveText.isEmpty ? (capture.isRecording ? "Listening…" : "") : capture.liveText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(capture.liveText.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if capture.isRecording, let started = capture.startedAt {
                Text(elapsedString(since: started, now: clockNow))
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(capture.isRecording ? 0.16 : 0.06))
        )
    }

    // MARK: - Responsive Control Bar

    /// Insert/read actions on the left, Send then Record on the right;
    /// in horizontal island mode the record switch sits centered on the pill anchor.
    @ViewBuilder
    private func controlBar(layout: ResponsiveHUDLayout) -> some View {
        let vikActive = vik.map { $0.isResponding || $0.phase == .listening } ?? false
        let islandHit = island?.isEnabled == true
            ? CGSize(width: HUDIslandGeometry.length, height: layout.controlBarHeight)
            : nil
        if let island, island.isEnabled, island.edge.isHorizontal {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    leadingControlItems(layout: layout, vikActive: vikActive)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                micSwitch(hitSize: islandHit)

                HStack(spacing: 6) {
                    trailingControlItems(layout: layout, vikActive: vikActive)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, layout.showsTimer ? 8 : 6)
        } else if let island, island.isEnabled, island.edge == .left {
            HStack(spacing: 6) {
                micSwitch(hitSize: islandHit)
                leadingControlItems(layout: layout, vikActive: vikActive)
                if !barShowsText(layout: layout, vikActive: vikActive) {
                    Spacer(minLength: 0)
                }
                trailingControlItems(layout: layout, vikActive: vikActive)
            }
            .padding(.horizontal, layout.showsTimer ? 8 : 6)
        } else {
            HStack(spacing: 6) {
                leadingControlItems(layout: layout, vikActive: vikActive)
                if !barShowsText(layout: layout, vikActive: vikActive) {
                    Spacer(minLength: 0)
                }
                trailingControlItems(layout: layout, vikActive: vikActive)
                micSwitch(hitSize: islandHit)
            }
            .padding(.horizontal, layout.showsTimer ? 8 : 6)
        }
    }

    /// Bar text exists only when the stream above is closed.
    private func barShowsText(layout: ResponsiveHUDLayout, vikActive: Bool) -> Bool {
        layout.showsStatusText || (vikActive && layout.showsLeadingActions && !layout.showsList)
    }

    @ViewBuilder
    private func leadingControlItems(layout: ResponsiveHUDLayout, vikActive: Bool) -> some View {
        let vikInBar = vikActive && !layout.showsList
        if layout.showsLeadingActions && !vikInBar {
            HStack(spacing: 2) {
                StudioBarButton(icon: "camera.viewfinder",
                                help: "Screenshot of this screen as a new note (⌥⌘S)") {
                    saveQuickNote { [try await QuickNotes.screenshot()] }
                }
                StudioBarButton(icon: "doc.on.clipboard",
                                help: "Clipboard (image, files or text) as a new note (⌥C)") {
                    saveQuickNote { try QuickNotes.pasteClipboard() }
                }
                // Adding a note and opening a place are different jobs.
                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 7)
                    .accessibilityHidden(true)
                StudioBarButton(icon: "doc.text",
                                help: "Open Personal Document") {
                    onOpenDocument()
                }
                if let onOpenWeb {
                    StudioBarButton(icon: "globe",
                                    help: "Открыть Studio в вебе (запустит сервис)") {
                        onOpenWeb()
                    }
                }
            }
        }

        if vikInBar, layout.showsLeadingActions, let vik {
            Image(systemName: capture.isRecording ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 11))
                .accessibilityLabel(capture.isRecording ? "Записываю" : "Микрофон выключен")
            Text(vik.compactText)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(vik.compactText)
        } else if layout.showsStatusText {
            Button {
                if let file = headlineNoteURL { onOpenNote(file) }
            } label: {
                Text(barHeadline)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(capture.isRecording ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(headlineNoteURL == nil)
            .help(headlineNoteURL == nil || island?.showsPill == true ? "" : "Открыть заметку")
            .accessibilityLabel("Открыть заметку из строки состояния")
        }
    }

    @ViewBuilder
    private func trailingControlItems(layout: ResponsiveHUDLayout, vikActive: Bool) -> some View {
        if !vikActive, layout.showsTimer, !layout.showsList, let started = capture.startedAt, capture.isRecording {
            Text(elapsedString(since: started, now: clockNow))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
        }

        if layout.showsSend, let vik, vik.isResponding {
            StudioBarButton(icon: "stop.circle", help: "Остановить ответ Алёны") { vik.cancel() }
        } else if layout.showsSend, let vik, vik.phase == .listening {
            StudioBarButton(icon: "paperplane.fill", help: "Отправить запрос Алёне",
                            isEnabled: !vik.request.isEmpty) { vik.sendNow() }
        } else if layout.showsSend && capture.isRecording {
            StudioBarButton(icon: "paperplane.fill",
                            help: "Send this note and keep recording (⌥X; ⌥S in HUD)",
                            isEnabled: !capture.isSending) {
                Task { await capture.send() }
            }
            .keyboardShortcut("s", modifiers: .option)
        }

        if layout.showsSend, let island, island.isEnabled, !collapsesFromListCorner(layout) {
            StudioBarButton(icon: "chevron.up.chevron.down",
                            help: "Collapse to the screen edge") {
                island.onToggle()
            }
        }
    }

    private func micSwitch(hitSize: CGSize?) -> some View {
        StudioMicSwitch(
            isRecording: capture.isRecording,
            isBusy: capture.isBusy,
            pulse: Int(clockNow.timeIntervalSinceReferenceDate) % 2 == 0,
            level: capture.isRecording ? CGFloat(capture.level) : 0,
            hitSize: hitSize,
            action: { capture.toggle() }
        )
    }

    private func saveQuickNote(_ make: @escaping @MainActor () async throws -> [URL]) {
        if let onSaveQuickNote {
            onSaveQuickNote(make)
            return
        }
        Task { @MainActor in
            do {
                _ = try await make()
                capture.errorMessage = nil
                recentNotes.reload()
            } catch {
                capture.errorMessage = error.localizedDescription
            }
        }
    }

    private var barHeadline: String {
        if let vik, vik.isResponding || vik.phase == .listening { return vik.status }
        if let err = capture.errorMessage, !capture.isRecording { return err }
        if !capture.liveText.isEmpty {
            // After a stop the live text stays until the note's file run lands.
            if capture.phase == .idle, let url = capture.recordingURL,
               let note = recentNotes.notes.last(where: { $0.fileURL == url }), note.hasFileTranscript {
                return note.studioTitle
            }
            return capture.liveText
        }
        if let anchor = capture.listeningAnchor {
            return "Commenting: “\(anchor.target.selector.quote)”"
        }
        if capture.isRecording { return "Listening…" }
        if let last = recentNotes.notes.last { return last.studioTitle }
        return "Ready"
    }

    private var borderOverlay: some View {
        let pulse = Int(clockNow.timeIntervalSinceReferenceDate) % 2 == 0
        let collapsed = island?.showsPill == true
        let width: CGFloat = capture.isRecording && !collapsed ? 2 : 1
        let color: Color = capture.isRecording && !collapsed
            ? Color.red.opacity(pulse ? 0.95 : 0.45)
            : Color.white.opacity(collapsed ? 0.1 : 0.16)
        // Stroke is centered on the edge: double it and clip to keep the inner half.
        return hudShape
            .stroke(color, lineWidth: width * 2)
            .clipShape(hudShape)
            .animation(.easeInOut(duration: 0.35), value: pulse)
            .allowsHitTesting(false)
    }

    private func elapsedString(since start: Date, now: Date) -> String {
        let sec = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func anchorIcon(_ state: VoiceAnchor.State) -> String {
        switch state {
        case .listening: "waveform"
        case .transcribing: "ellipsis.circle"
        case .posted: "checkmark.circle.fill"
        case .empty: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func anchorColor(_ state: VoiceAnchor.State) -> Color {
        switch state {
        case .listening: .red
        case .transcribing: .orange
        case .posted: .green
        case .empty: .secondary
        case .failed: .red
        }
    }

    private func anchorLabel(_ state: VoiceAnchor.State) -> String {
        switch state {
        case .listening: "Listening for comment…"
        case .transcribing: "Transcribing spoken comment…"
        case .posted(let text): text
        case .empty: "No speech detected for selection"
        case .failed(let msg): msg
        }
    }
}

/// Vik's citations as short links instead of raw `[N:UUID]` / `[b12]` tokens.
enum VikReplyText {
    static let scheme = "wimm-hud"

    /// `noteLabel` returns a label for a note the HUD can open, or nil.
    static func attributed(_ text: String, noteLabel: (String) -> String?) -> AttributedString {
        let token = #/\[(?:(D\d+|b\d+)|N:([A-Za-z0-9-]+))\]/#
        var out = AttributedString()
        var rest = text[...]
        while let match = rest.firstMatch(of: token) {
            out += AttributedString(String(rest[..<match.range.lowerBound]))
            var chip: AttributedString
            if let block = match.output.1 {
                chip = AttributedString(String(block))
                chip.link = URL(string: "\(scheme)://doc/\(block)")
            } else {
                let id = String(match.output.2 ?? "")
                let label = noteLabel(id)
                chip = AttributedString(label ?? "заметка")
                if label != nil { chip.link = URL(string: "\(scheme)://note/\(id)") }
                else { chip.foregroundColor = .secondary }
            }
            chip.font = .system(size: 10.5, weight: .semibold, design: .rounded)
            out += chip
            rest = rest[match.range.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

/// Icon button sized to fit the 38pt bar.
struct StudioBarButton: View {
    let icon: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.secondary)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
    }
}

/// Uses the shared Wimm `RecordingSwitchStyle` toggle at every HUD width, down to 76x32.
/// The input level breathes behind the switch, so there is no separate meter.
struct StudioMicSwitch: View {
    let isRecording: Bool
    let isBusy: Bool
    let pulse: Bool
    var level: CGFloat = 0
    var hitSize: CGSize? = nil
    let action: () -> Void

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { isRecording },
                set: { requested in
                    guard requested != isRecording else { return }
                    action()
                }
            )
        ) {
            Text(isRecording ? "Recording" : "Record")
        }
        .toggleStyle(RecordingSwitchStyle(showsLabel: false, pulseOn: pulse, hitSize: hitSize, level: level))
        .focusEffectDisabled()
        .disabled(isBusy)
        .keyboardShortcut("x", modifiers: [])
        .help(isRecording ? "Stop recording (⌥W; X in HUD)" : "Start recording (⌥W; X in HUD)")
    }
}

/// Decides whether the HUD stream keeps following its newest line. Growing
/// content never turns following off; only the user moving the list up does,
/// and reaching the end again turns it back on.
enum HUDTailFollow {
    static let slack: CGFloat = 24

    static func isAtEnd(offsetY: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat) -> Bool {
        offsetY + viewportHeight >= contentHeight - slack
    }

    static func next(current: Bool, previousOffsetY: CGFloat, offsetY: CGFloat, atEnd: Bool) -> Bool {
        if atEnd { return true }
        if offsetY < previousOffsetY - 0.5 { return false }
        return current
    }
}

private struct TailFollowTracker: ViewModifier {
    @Binding var followsTail: Bool

    private struct Geometry: Equatable {
        var offsetY: CGFloat
        var atEnd: Bool
    }

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Geometry.self) { geometry in
                Geometry(
                    offsetY: geometry.contentOffset.y,
                    atEnd: HUDTailFollow.isAtEnd(
                        offsetY: geometry.contentOffset.y,
                        viewportHeight: geometry.containerSize.height,
                        contentHeight: geometry.contentSize.height))
            } action: { old, new in
                let next = HUDTailFollow.next(
                    current: followsTail, previousOffsetY: old.offsetY,
                    offsetY: new.offsetY, atEnd: new.atEnd)
                if next != followsTail { followsTail = next }
            }
        } else {
            content
        }
    }
}
