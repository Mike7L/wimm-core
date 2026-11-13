import AppKit
import SwiftUI
import WimmDocumentUI
import WimmInfrastructure
import WimmSecretary

/// What the secretary window needs from the document window that owns the secretary.
/// Closures, not values: the window lives on while the document changes underneath it.
struct SecretaryWindowActions {
    var document: @MainActor () -> URL?
    var pendingThreads: @MainActor () -> Int
    /// False while the document is being edited by hand (Studio) or is not a workspace.
    var canStart: @MainActor () -> Bool
    var answerComments: @MainActor () -> Void
    var runPass: @MainActor () -> Void

    init(document: @escaping @MainActor () -> URL?, pendingThreads: @escaping @MainActor () -> Int,
                canStart: @escaping @MainActor () -> Bool, answerComments: @escaping @MainActor () -> Void,
                runPass: @escaping @MainActor () -> Void) {
        self.document = document; self.pendingThreads = pendingThreads; self.canStart = canStart
        self.answerComments = answerComments; self.runPass = runPass
    }
}

/// Studio's secretary window: settings on the left, the queue, the
/// selected run and the run history on the right. It never blocks the document, and closing it
/// never stops a run.
@MainActor
enum SecretaryWindow {
    private static var windows: [ObjectIdentifier: NSWindow] = [:]
    private static var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    static func show(_ secretary: PersonalDocumentSecretary, actions: SecretaryWindowActions) {
        let key = ObjectIdentifier(secretary)
        if let window = windows[key] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SecretaryWindowView(secretary: secretary, actions: actions))
        host.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: host)
        window.title = "Секретарь"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1000, height: 740))
        if !window.setFrameUsingName("WimmSecretaryWindow") { window.center() }
        window.setFrameAutosaveName("WimmSecretaryWindow")
        windows[key] = window
        observers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                windows[key] = nil
                if let observer = observers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

struct SecretaryWindowView: View {
    let secretary: PersonalDocumentSecretary
    let actions: SecretaryWindowActions

    init(secretary: PersonalDocumentSecretary, actions: SecretaryWindowActions) {
        self.secretary = secretary; self.actions = actions
    }

    @State private var history: [SecretaryRunSummary] = []
    @State private var selectedRunID: String?
    @State private var format = 1
    @State private var formatAvailable = false
    @State private var settingsError: String?
    @State private var showsLog = true
    @AppStorage("Secretary.budgetUSD") private var budget: Double = 2

    private var workspace: SecretaryWorkspace? { actions.document().flatMap(SecretaryWorkspace.init(document:)) }
    private var selectedRun: SecretaryRunSummary? {
        history.first { $0.id == selectedRunID } ?? history.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                ScrollView { settings.padding(16) }
                    .frame(width: 320)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        queueCard
                        runCard
                        logSection
                        historySection
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: secretary.phase) { _, phase in
            if phase == .running { showsLog = true }
            if phase == .finished { reload(); selectedRunID = history.first?.id }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Секретарь").font(.title2.weight(.semibold))
                Text(workspace?.document.lastPathComponent ?? "Документ не в рабочей папке секретаря")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            status
            let pending = actions.pendingThreads()
            Button("Ответить на комментарии (\(pending))") { actions.answerComments() }
                .disabled(pending == 0 || !startable || secretary.agent == .gemini)
                .help(secretary.agent == .gemini ? "Gemini поддерживает только проход по пакету заметок" : "")
            Button("Запустить проход") { actions.runPass() }
                .buttonStyle(.borderedProminent)
                .disabled(!startable)
            if secretary.isRunning {
                Button("Отменить", role: .cancel) { secretary.cancel() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var startable: Bool { !secretary.isRunning && workspace != nil && actions.canStart() }

    @ViewBuilder private var status: some View {
        if secretary.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                if let start = secretary.startedAt {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("Идёт · " + Self.duration(context.date.timeIntervalSince(start)))
                            .monospacedDigit()
                    }
                } else {
                    Text("Идёт")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
        } else if let error = secretary.errorMessage {
            Label("Не запустился", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange).help(error)
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Исполнитель") {
                Picker("Агент", selection: Bindable(secretary).agent) {
                    ForEach(SecretaryAgent.allCases) { Text($0.displayName).tag($0) }
                }
                let options = secretary.agent.modelOptions(including: secretary.model)
                if !options.isEmpty {
                    Picker("Модель", selection: Bindable(secretary).model) {
                        ForEach(options) { Text($0.displayName).tag($0.id) }
                    }
                }
                TextField("Другая модель (id)", text: Bindable(secretary).model)
                    .textFieldStyle(.roundedBorder)
                if secretary.agent == .claude {
                    Stepper(value: $budget, in: 0.5...50, step: 0.5) {
                        Text("Лимит расходов: ") + Text(String(format: "$%.2f", budget)).monospacedDigit()
                    }
                }
            }

            section("Ответ модели") {
                note("Правки (формат 2): модель возвращает короткие правки, источники без добавлений и препятствия. Хост применяет ответ целиком и ведёт учёт.")
            }

            section("Усилие модели") {
                Picker("", selection: Bindable(secretary).effort) {
                    Text("Авто").tag("")
                    Text("Низкое").tag("low")
                    Text("Среднее").tag("medium")
                    Text("Высокое").tag("high")
                }
                .pickerStyle(.segmented).labelsHidden()
                note(secretary.effort.isEmpty
                     ? "Авто: собственная настройка агента; Haiku в формате правок думает с высоким усилием."
                     : "Задано вручную для всех запусков из приложения. Выше усилие — дольше и дороже ответ.")
            }

            section("Пакет") {
                SecretaryPacketSizeControl(value: Bindable(secretary).packetSourceKB, label: "Размер пакета",
                                           hint: "Объём заметок за один проход. Крупная заметка может идти отдельно, до двойного лимита.",
                                           unit: "КБ")
                SecretaryOptimizationLevelControl(level: Bindable(secretary).optimizationLevel)
            }

            if let settingsError {
                Text(settingsError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            note("Перед запуском документ копируется в docs/.backups. В приватном режиме запуск запрещён.")
        }
        .disabled(secretary.isRunning)
    }

    // MARK: Queue

    private var queueCard: some View {
        let record = secretary.record ?? history.first?.record
        let queues = record?.hostQueues
        return card("Очередь") {
            HStack(spacing: 8) {
                tile(record?.remainingNotes, "осталось заметок")
                tile(queues?.waitingForText, "ждут текста")
                tile(queues?.waitingForViewing, "ждут просмотра")
                tile(queues?.unfinished, "не доделано")
                tile(queues?.skipped, "пропущено")
            }
            note(record == nil ? "Запусков ещё не было." : "По последнему запуску; «—» — запуск этого не сообщил.")
        }
    }

    // MARK: Selected run

    @ViewBuilder private var runCard: some View {
        if let run = selectedRun {
            card(run.id == history.first?.id ? "Последний запуск" : "Запуск") {
                runHeader(run)
                if let edits = run.edits { editsView(edits) }
                if let record = run.record {
                    if let summary = record.result?.summary ?? record.finalText, !summary.isEmpty {
                        Text(summary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = record.error, record.outcome != .succeeded {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(8)
                    }
                    ForEach(record.findings, id: \.self) { finding in
                        Label(finding, systemImage: "exclamationmark.triangle").font(.caption)
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if let requeued = record.requeuedNotes, !requeued.isEmpty {
                        note("Возвращены в очередь из-за пропавших ссылок: \(requeued.count)")
                    }
                }
                HStack {
                    Button("Папка запуска") { NSWorkspace.shared.activateFileViewerSelecting([run.directory]) }
                    if let backup = run.record?.backup, let root = workspace?.root {
                        Button("Резервная копия") {
                            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(backup)])
                        }
                    }
                }
                .controlSize(.small)
            }
        } else if let error = secretary.errorMessage {
            card("Последний запуск") {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private func runHeader(_ run: SecretaryRunSummary) -> some View {
        let record = run.record
        let ok = record?.outcome == .succeeded && (record?.findings.isEmpty ?? true) && (run.edits?.accepted ?? true)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                Text(Self.outcomeTitle(record?.outcome)).font(.headline)
                Text(Self.kindTitle(record?.kind)).foregroundStyle(.secondary)
                Spacer()
                if let cost = record?.costUSD {
                    Text(String(format: "$%.2f", cost)).font(.headline).monospacedDigit()
                } else {
                    Text("цена неизвестна").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(Self.facts(run)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func editsView(_ edits: SecretaryRunSummary.Edits) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                tile(edits.count("used"), "внесено")
                tile(edits.count("reviewed"), "без добавлений")
                tile(edits.count("unfinished"), "не доделано")
                tile(edits.count("unmentioned"), "не упомянуто")
                tile(edits.count("rejected"), "отклонено")
            }
            if !edits.accepted {
                Label("Ответ отклонён целиком" + (edits.rejection.map { ": \($0)" } ?? ""), systemImage: "xmark.octagon")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            } else {
                note("Правок применено: \(edits.editCount)")
            }
            if edits.lazyReply {
                note("Ответ без правок со слишком длинными списками: источники остались в очереди.")
            }
            if !edits.unfinished.isEmpty {
                DisclosureGroup("Не доделано (\(edits.unfinished.count))") {
                    entries(edits.unfinished)
                }
            }
            if !edits.deleted.isEmpty {
                DisclosureGroup("Удалённый текст (\(edits.deleted.count))") {
                    entries(edits.deleted)
                }
            }
        }
    }

    private func entries(_ list: [SecretaryRunSummary.Edits.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list, id: \.self) { entry in
                (Text(entry.source).bold() + Text(entry.detail.map { " — \($0)" } ?? ""))
                    .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Log and history

    @ViewBuilder private var logSection: some View {
        if !secretary.log.isEmpty {
            DisclosureGroup("Журнал текущего запуска (\(secretary.log.count))", isExpanded: $showsLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(secretary.log.enumerated()), id: \.offset) { index, event in
                                Text(Self.line(event)).font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(event.kind == .error ? Color.red : (event.kind == .info ? .secondary : .primary))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 220)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .onChange(of: secretary.log.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var historySection: some View {
        if !history.isEmpty {
            card("История") {
                VStack(spacing: 0) {
                    ForEach(history) { run in
                        historyRow(run)
                        if run.id != history.last?.id { Divider() }
                    }
                }
            }
        }
    }

    private func historyRow(_ run: SecretaryRunSummary) -> some View {
        let selected = run.id == selectedRun?.id
        let record = run.record
        return Button {
            selectedRunID = run.id
        } label: {
            HStack(spacing: 10) {
                Circle().fill(Self.outcomeColor(run)).frame(width: 8, height: 8)
                Text(run.startedAt.map(Self.dateText) ?? run.id).monospacedDigit().frame(width: 120, alignment: .leading)
                Text(Self.kindTitle(record?.kind)).frame(width: 90, alignment: .leading)
                Text(Self.shortModel(record?.model)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let edits = run.edits {
                    Text("внесено \(edits.count("used"))").foregroundStyle(.secondary)
                }
                Text(record?.costUSD.map { String(format: "$%.2f", $0) } ?? "—")
                    .monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            .font(.callout)
            .padding(.vertical, 6).padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: Pieces

    private func reload() {
        guard let workspace else { history = []; formatAvailable = false; return }
        history = SecretaryRunHistory.recent(workspace)
        format = SecretaryResponseFormatSetting.current(workspace)
        formatAvailable = SecretaryResponseFormatSetting.isAvailable(workspace)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    private func tile(_ value: Int?, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.map(String.init) ?? "—").font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Formatting

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func facts(_ run: SecretaryRunSummary) -> String {
        guard let record = run.record else { return run.id }
        var parts: [String] = []
        if let start = run.startedAt { parts.append(dateText(start)) }
        parts.append(shortModel(record.model))
        if let start = parse(record.startedAt), let end = parse(record.finishedAt) {
            parts.append(duration(end.timeIntervalSince(start)))
        }
        if record.tokensIn != nil || record.tokensOut != nil {
            parts.append("токены \(record.tokensIn.map(String.init) ?? "?") → \(record.tokensOut.map(String.init) ?? "?")")
        }
        if let workflow = record.workflow { parts.append(workflow) }
        return parts.joined(separator: " · ")
    }

    static func shortModel(_ model: String?) -> String {
        guard let model, !model.isEmpty else { return "модель по умолчанию" }
        return model.replacingOccurrences(of: "models/", with: "").replacingOccurrences(of: "claude-", with: "")
    }

    static func outcomeTitle(_ outcome: SecretaryRunRecord.Outcome?) -> String {
        switch outcome {
        case .succeeded: "Завершён"
        case .incomplete: "Не завершён"
        case .cancelled: "Отменён"
        case .failed: "Ошибка"
        case nil: "Без итога"
        }
    }

    static func kindTitle(_ kind: SecretaryRunKind?) -> String {
        switch kind {
        case .comments: "комментарии"
        case .pass: "проход"
        default: ""
        }
    }

    static func outcomeColor(_ run: SecretaryRunSummary) -> Color {
        switch run.record?.outcome {
        case .succeeded: (run.record?.findings.isEmpty ?? true) && (run.edits?.accepted ?? true) ? .green : .orange
        case .incomplete, .cancelled: .orange
        case .failed: .red
        case nil: .secondary
        }
    }

    static func line(_ event: SecretaryEvent) -> String {
        let mark = switch event.kind { case .info: "·"; case .text: "›"; case .tool: "⚙"; case .error: "!" }
        return "\(mark) \(event.message)"
    }
}
