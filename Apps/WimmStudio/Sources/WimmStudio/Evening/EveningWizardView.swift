import AppKit
import SwiftUI
import WimmDomain
import WimmInfrastructure

/// The evening window's content: the conversation by default, the whole note
/// ("Вся заметка", `EveningView`) on request. Owns what both faces share —
/// the recorder, today's photos, following the library, the final save.
struct EveningRootView: View {
    @Bindable var model: EveningModel
    let recentNotes: RecentNotes
    let capture: CaptureSession
    let onOpenNote: (URL) -> Void
    let onFilesAdded: ([URL]) -> Void
    let onClose: () -> Void
    var initialStep: EveningStep = .day
    /// Off in tests: PhotoKit would ask for access.
    var loadsPhotos = true
    @State private var recorder = EveningVoiceRecorder()
    @State private var photos = EveningPhotos()
    @State private var showsWholeNote = false

    var body: some View {
        Group {
            if showsWholeNote {
                EveningView(model: model, recentNotes: recentNotes, capture: capture, onOpenNote: onOpenNote,
                            onFilesAdded: onFilesAdded, recorder: recorder, photos: photos,
                            onConversation: { switchFace(toWholeNote: false) })
            } else {
                EveningWizardView(model: model, recentNotes: recentNotes, capture: capture, recorder: recorder,
                                  photos: photos, onOpenNote: onOpenNote, onFilesAdded: onFilesAdded,
                                  onWholeNote: { switchFace(toWholeNote: true) }, onClose: onClose,
                                  initialStep: initialStep)
            }
        }
        .task { model.update(notes: recentNotes.allNotes) }
        .task { if loadsPhotos { await photos.load(day: model.day) } }
        .onChange(of: recentNotes.revision) { model.update(notes: recentNotes.allNotes) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            if let answer = recorder.finishForTermination() {
                model.attachAnswer(audio: answer.url, text: answer.text, prompt: answer.prompt)
            }
        }
        .onDisappear {
            Task { @MainActor in
                await EveningAnswerFlow.finishRecording(recorder, model: model)
                await model.saveNow()
            }
        }
    }

    private func switchFace(toWholeNote: Bool) {
        Task { @MainActor in
            await EveningAnswerFlow.finishRecording(recorder, model: model)
            showsWholeNote = toWholeNote
        }
    }
}

/// One screen of the evening conversation.
enum EveningStep: Hashable {
    case day, photos, prompt(Int), thoughts, done

    /// The walk for tonight. Photos only when the library has some for the day.
    static func walk(hasPhotos: Bool, promptCount: Int) -> [EveningStep] {
        [.day] + (hasPhotos ? [.photos] : []) + (0..<promptCount).map { .prompt($0) } + [.thoughts, .done]
    }
}

/// Recording an answer, shared by both faces of the window.
@MainActor
enum EveningAnswerFlow {
    static func toggle(_ recorder: EveningVoiceRecorder, heading: String, model: EveningModel) async {
        if recorder.isRecording {
            await finishRecording(recorder, model: model)
            return
        }
        do {
            _ = try model.ensureFile()
            await recorder.start(prompt: heading, audioURL: try EveningJournalStore.newAnswerAudioURL())
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    /// Spoken text goes in as heard: uncertain recognition is not "fixed".
    static func finishRecording(_ recorder: EveningVoiceRecorder, model: EveningModel) async {
        guard let result = await recorder.stop() else { return }
        model.attachAnswer(audio: result.url, text: result.text, prompt: result.prompt)
        await model.saveNow()
    }
}

// MARK: - Conversation

/// The evening as a short talk with a friend, one screen at a time: the day
/// as it was recorded, the day's photos, two questions, anything else, done.
/// ⌘↩ goes on, Esc skips, nothing is required.
struct EveningWizardView: View {
    @Bindable var model: EveningModel
    let recentNotes: RecentNotes
    let capture: CaptureSession
    let recorder: EveningVoiceRecorder
    let photos: EveningPhotos
    let onOpenNote: (URL) -> Void
    let onFilesAdded: ([URL]) -> Void
    let onWholeNote: () -> Void
    let onClose: () -> Void
    @State private var step: EveningStep
    @State private var showsHours = false
    @State private var hovered: String?
    @State private var isEditingDigest = false
    @State private var isClosing = false
    @FocusState private var answerFocused: Bool

    init(model: EveningModel, recentNotes: RecentNotes, capture: CaptureSession, recorder: EveningVoiceRecorder,
         photos: EveningPhotos, onOpenNote: @escaping (URL) -> Void, onFilesAdded: @escaping ([URL]) -> Void,
         onWholeNote: @escaping () -> Void, onClose: @escaping () -> Void, initialStep: EveningStep = .day) {
        self.model = model; self.recentNotes = recentNotes; self.capture = capture
        self.recorder = recorder; self.photos = photos
        self.onOpenNote = onOpenNote; self.onFilesAdded = onFilesAdded
        self.onWholeNote = onWholeNote; self.onClose = onClose
        _step = State(initialValue: initialStep)
    }

    private var steps: [EveningStep] {
        EveningStep.walk(hasPhotos: photos.access == .granted && !photos.candidates.isEmpty,
                         promptCount: model.prompts.count)
    }

    private var index: Int { steps.firstIndex(of: step) ?? 0 }
    private var isBusy: Bool { recorder.phase == .starting || recorder.phase == .finishing || isClosing }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                if showsHours {
                    EveningHourScale(model: model, hovered: $hovered, onOpen: openMetadata, onDropFiles: dropFiles)
                        .frame(width: 150)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                ScrollView {
                    page
                        .id(step)
                        .padding(.horizontal, 40).padding(.top, 44).padding(.bottom, 24)
                        .frame(maxWidth: 640, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EveningKeyMonitor(onCommandReturn: { if !isBusy { goForward() } }, onEscape: escape))
    }

    // MARK: - Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsHours.toggle() }
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .buttonStyle(.borderless)
            .help(showsHours ? "Скрыть день по часам" : "Показать день по часам")
            Text(model.document.title).font(.headline)
            Spacer()
            progress
            Spacer()
            Button("Вся заметка", action: onWholeNote)
                .buttonStyle(.borderless)
                .disabled(isBusy)
                .help("Вечер одной страницей, как в заметке")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Dots, not a counter: where we are, and how much is left, at a glance.
    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { offset, candidate in
                Button { go(to: candidate) } label: {
                    Circle()
                        .fill(offset == index ? Color.accentColor : Color.secondary.opacity(offset < index ? 0.55 : 0.22))
                        .frame(width: 6, height: 6)
                        .padding(3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy || candidate == .done && model.closedAt == nil)
                .help(Self.stepName(candidate))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Шаг \(index + 1) из \(steps.count)")
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if index > 0 {
                Button { go(to: steps[index - 1]) } label: { Label("Назад", systemImage: "chevron.left") }
                    .disabled(isBusy)
            }
            if let error = model.errorMessage ?? recorder.errorMessage ?? photos.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
                    .lineLimit(2)
            }
            Spacer()
            if step != .done && step != .day {
                Button { skip() } label: { hint("Пропустить", key: "esc") }
                    .disabled(isBusy)
            }
            Button { goForward() } label: { hint(forwardTitle, key: "⌘↩") }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func hint(_ title: String, key: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(key).font(.caption).opacity(0.6)
        }
    }

    private var forwardTitle: String {
        switch step {
        case .thoughts: "Закрыть день"
        case .done: "Готово"
        default: "Дальше"
        }
    }

    // MARK: - Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .day: dayPage
        case .photos: photosPage
        case .prompt(let i): promptPage(i)
        case .thoughts: thoughtsPage
        case .done: donePage
        }
    }

    private func say(_ line: String, _ aside: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line)
                .font(.system(size: 24, weight: .regular, design: .serif))
                .fixedSize(horizontal: false, vertical: true)
            if let aside {
                Text(aside).font(.system(size: 15)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var dayPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            say(Self.greeting(model.dayNotes), dayAside)
            if !model.digestBody.isEmpty || isEditingDigest { digestCard }
        }
    }

    private var dayAside: String {
        var aside = model.dayNotes.isEmpty
            ? "Ничего страшного. Можно просто рассказать, как прошёл день."
            : "Вот черновик дня по ним. Поправь, если что-то не так."
        if let closed = model.closedAt {
            aside += " День уже закрыт в \(closed.formatted(date: .omitted, time: .shortened)), но дописать можно."
        }
        return aside
    }

    private var digestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isEditingDigest {
                TextEditor(text: Binding(get: { model.digestBody },
                                         set: { model.setBody($0, of: EveningJournal.digestHeading) }))
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 180)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.digestBody.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        digestLine(line)
                    }
                }
            }
            HStack(spacing: 14) {
                Button(isEditingDigest ? "Готово" : "Поправить") { isEditingDigest.toggle() }
                if !model.isDigestUntouched {
                    Button("Собрать заново") { model.rebuildDigest() }
                }
                let missing = model.missingLines
                if !missing.isEmpty {
                    Button("Добавить \(missing.count) \(Self.plural(missing.count, "новую запись", "новые записи", "новых записей"))") {
                        model.addMissingLines()
                    }
                }
                Spacer()
            }
            .buttonStyle(.link).font(.callout)
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    /// "- 16:06 — [title](sidecar)": the time in its own column, the title opens the note.
    private func digestLine(_ line: String) -> some View {
        var text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
        var time = ""
        if let dash = text.range(of: " — "), text.distance(from: text.startIndex, to: dash.lowerBound) <= 5 {
            time = String(text[..<dash.lowerBound])
            text = String(text[dash.upperBound...])
        }
        let names = EveningJournal.linkedMetadataNames(in: line)
        let isHovered = hovered.map { names.contains($0) } ?? false
        let attributed = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(attributed).font(.system(size: 15))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(isHovered ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { inside in hovered = inside ? names.first : (isHovered ? nil : hovered) }
        .environment(\.openURL, OpenURLAction { url in
            openMetadata(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            return .handled
        })
    }

    private var photosPage: some View {
        let added = photos.candidates.filter(\.isAdded).count
        return VStack(alignment: .leading, spacing: 22) {
            say("Из фото за день что-нибудь оставить?",
                "Нажми на снимок, и он встанет в день по времени съёмки.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 10)], spacing: 10) {
                ForEach(photos.candidates) { photoTile($0) }
            }
            if added > 0 {
                Text("В дне \(added) \(Self.plural(added, "фото", "фото", "фото")).").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func photoTile(_ candidate: EveningPhotos.Candidate) -> some View {
        Button {
            Task { if let url = await photos.add(candidate) { onFilesAdded([url]) } }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = candidate.thumbnail {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(minWidth: 104, maxWidth: 140, minHeight: 104, maxHeight: 104)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(candidate.isAdded ? 0.5 : 1)
                if candidate.isAdded {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .green).padding(6)
                } else if photos.importing.contains(candidate.id) {
                    ProgressView().controlSize(.small).padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(candidate.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(.black.opacity(0.45)).foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 3)).padding(5)
            }
        }
        .buttonStyle(.plain)
        .disabled(candidate.isAdded)
        .help(candidate.isAdded ? "Уже в дне" : "Добавить в день")
    }

    private func promptPage(_ i: Int) -> some View {
        let prompt = model.prompts[i]
        let lead = i == 0 ? "Пара вопросов. Отвечай как удобно: голосом, текстом или никак." : "И ещё один."
        return VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(lead).font(.system(size: 15)).foregroundStyle(.secondary)
                Text(prompt).font(.system(size: 24, weight: .regular, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
            }
            answer(prompt, placeholder: "Можно написать здесь", minHeight: 120)
        }
    }

    private var thoughtsPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            say("Что ещё хочется сказать?",
                "Мысль, которая крутится, или то, что не влезло в вопросы. Можно и ничего.")
            answer(EveningJournal.thoughtsHeading, placeholder: "Что угодно", minHeight: 160)
        }
    }

    private var donePage: some View {
        let saved = Self.savedSummary(model: model, addedPhotos: photos.candidates.filter(\.isAdded).count)
        return VStack(alignment: .leading, spacing: 22) {
            say(model.closedAt == nil ? "Спасибо." : "Спасибо, день закрыт.",
                saved.isEmpty ? "Заметка почти пустая, и это нормально. К ней можно вернуться завтра."
                    : "Всё лежит в заметке «\(model.document.title)».")
            if !saved.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(saved, id: \.self) { item in
                        Label(item, systemImage: "checkmark").font(.system(size: 15))
                            .labelStyle(EveningCheckLabelStyle())
                    }
                }
            }
            Button("Открыть заметку") { if let file = model.file { onOpenNote(file) } }
                .buttonStyle(.link)
                .disabled(model.file == nil)
        }
    }

    // MARK: - Answering

    private func answer(_ heading: String, placeholder: String, minHeight: CGFloat) -> some View {
        let isThisRecording = recorder.isRecording && recorder.prompt == heading
        let text = Binding(get: { model.body(of: heading) }, set: { model.setBody($0, of: heading) })
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(model.answerAudio.filter { $0.prompt == heading }, id: \.url) { item in
                StudioNoteAudioPlayer(url: item.url)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .focused($answerFocused)
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 16)).foregroundStyle(.tertiary)
                        .padding(.leading, 5).allowsHitTesting(false)
                }
            }
            .frame(minHeight: minHeight)
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            HStack(alignment: .top, spacing: 12) {
                Button {
                    Task { await EveningAnswerFlow.toggle(recorder, heading: heading, model: model) }
                } label: {
                    Label(isThisRecording ? "Остановить" : "Сказать голосом",
                          systemImage: isThisRecording ? "stop.fill" : "mic.fill")
                }
                .controlSize(.large)
                .tint(isThisRecording ? .red : nil)
                .disabled(capture.isRecording || isBusy || (recorder.isRecording && !isThisRecording))
                .help(capture.isRecording ? "Сейчас идёт запись в HUD" : "Текст встанет сюда как услышан, аудио останется в заметке")
                if isThisRecording {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                            .scaleEffect(1 + CGFloat(recorder.level))
                            .padding(.top, 6)
                        Text(recorder.liveText.isEmpty ? "Слушаю…" : recorder.liveText)
                            .foregroundStyle(.secondary).italic()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Navigation

    private func go(to target: EveningStep) {
        Task { @MainActor in
            await EveningAnswerFlow.finishRecording(recorder, model: model)
            isEditingDigest = false
            withAnimation(.easeInOut(duration: 0.18)) { step = target }
            if case .prompt = target { answerFocused = true }
            if target == .thoughts { answerFocused = true }
        }
    }

    private func goForward() {
        switch step {
        case .thoughts:
            isClosing = true
            Task { @MainActor in
                await EveningAnswerFlow.finishRecording(recorder, model: model)
                await model.closeDay()
                isClosing = false
                if model.closedAt != nil { go(to: .done) }
            }
        case .done:
            onClose()
        default:
            go(to: steps[min(index + 1, steps.count - 1)])
        }
    }

    /// Skipping is an ordinary way through: whatever was written stays.
    private func skip() {
        guard step != .done else { return }
        if step == .thoughts {
            goForward()
        } else {
            go(to: steps[min(index + 1, steps.count - 1)])
        }
    }

    /// Esc first ends a recording, then leaves the digest editor, then skips.
    private func escape() {
        if recorder.isRecording {
            Task { await EveningAnswerFlow.finishRecording(recorder, model: model) }
        } else if isEditingDigest {
            isEditingDigest = false
        } else if !isBusy {
            skip()
        }
    }

    private func openMetadata(_ name: String) {
        let url = FileStore.recordingsDirectory().appendingPathComponent(name)
        if let note = StudioNoteLink.resolve(url, in: recentNotes.notesByURLPath) {
            onOpenNote(note.fileURL)
        }
    }

    private func dropFiles(_ urls: [URL], at date: Date) {
        let added = urls.filter { AttachmentType(fromExtension: $0.pathExtension) == .image }
            .compactMap { photos.addFile($0, fallbackDate: date) }
        if !added.isEmpty { onFilesAdded(added) }
    }

    // MARK: - Words

    static func stepName(_ step: EveningStep) -> String {
        switch step {
        case .day: "День"
        case .photos: "Фото"
        case .prompt(let i): "Вопрос \(i + 1)"
        case .thoughts: "Что ещё"
        case .done: "Итог"
        }
    }

    /// "Привет. Сегодня у тебя 6 записей, с 16:06 до 16:41."
    static func greeting(_ notes: [EveningJournal.DayNote]) -> String {
        guard let first = notes.first?.date, let last = notes.last?.date else {
            return "Привет. Сегодня записей не было."
        }
        let from = first.formatted(date: .omitted, time: .shortened)
        let to = last.formatted(date: .omitted, time: .shortened)
        if notes.count == 1 { return "Привет. Сегодня у тебя одна запись, в \(from)." }
        let count = "\(notes.count) \(plural(notes.count, "запись", "записи", "записей"))"
        return from == to ? "Привет. Сегодня у тебя \(count), в \(from)."
                          : "Привет. Сегодня у тебя \(count), с \(from) до \(to)."
    }

    /// What the evening note holds, one line each; nothing listed for what was skipped.
    @MainActor
    static func savedSummary(model: EveningModel, addedPhotos: Int) -> [String] {
        var items: [String] = []
        let lines = model.digestBody.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count
        if lines > 0 { items.append("День: \(lines) \(plural(lines, "строка", "строки", "строк"))") }
        if addedPhotos > 0 { items.append("Фото: \(addedPhotos)") }
        let answered = model.prompts.filter { !model.body(of: $0).isEmpty }.count
        if answered > 0 {
            items.append("Ответ\(answered == 1 ? "" : "ы") на \(answered == 1 ? "вопрос" : "\(answered) вопроса")")
        }
        let voice = model.answerAudio.count
        if voice > 0 { items.append("Голосом: \(voice) \(plural(voice, "запись", "записи", "записей"))") }
        if !model.body(of: EveningJournal.thoughtsHeading).isEmpty { items.append("Мысли") }
        return items
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let tens = n % 100, ones = n % 10
        if (11...14).contains(tens) { return many }
        if ones == 1 { return one }
        if (2...4).contains(ones) { return few }
        return many
    }
}

private struct EveningCheckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.foregroundStyle(.green).font(.system(size: 13, weight: .semibold))
            configuration.title
        }
    }
}

// MARK: - Keys

/// ⌘↩ and Esc for the whole window. A local monitor, because a focused text
/// editor eats Esc (it opens completions) before any button shortcut sees it.
struct EveningKeyMonitor: NSViewRepresentable {
    let onCommandReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handlers = (onCommandReturn, onEscape)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.handlers = (onCommandReturn, onEscape)
    }

    final class MonitorView: NSView {
        var handlers: (commandReturn: () -> Void, escape: () -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode, eventWindow = event.window.map(ObjectIdentifier.init)
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let handled = MainActor.assumeIsolated { self?.handle(keyCode: keyCode, modifiers: modifiers, in: eventWindow) ?? false }
                return handled ? nil : event
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            super.viewWillMove(toWindow: newWindow)
        }

        private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in eventWindow: ObjectIdentifier?) -> Bool {
            guard let window, ObjectIdentifier(window) == eventWindow, window.isKeyWindow else { return false }
            switch (keyCode, modifiers) {
            case (53, []):
                // Typing with an input method: let it have its Esc.
                if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return false }
                handlers?.escape()
                return true
            case (36, [.command]), (76, [.command]):
                handlers?.commandReturn()
                return true
            default:
                return false
            }
        }
    }
}
