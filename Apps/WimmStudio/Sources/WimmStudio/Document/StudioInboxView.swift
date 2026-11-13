import SwiftUI
import WimmInfrastructure

/// Left column of the document window: everything waiting for the owner,
/// each row a jump into the text, a source or a thread.
struct StudioInboxView: View {
    @Bindable var inbox: StudioInboxModel
    let document: PersonalDocument
    let threads: [DocumentCommentThread]
    let onReveal: (Int) -> Void
    let onRevealChange: (StudioInbox.Change) -> Void
    let onRevealQuestion: (Int) -> Void
    let onRevealThread: (DocumentCommentThread) -> Void
    let onOpenSource: (String) -> Void
    let onAnswered: (URL) -> Void

    @State private var expandedPasses: Set<String> = []
    @AppStorage("WimmStudio.inbox.collapsed") private var collapsedRaw = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6, pinnedViews: [.sectionHeaders]) {
                    changesSection
                    questionsSection
                    answeredSection
                    repliesSection
                    passesSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Что нового").font(.system(size: 13, weight: .semibold))
                Spacer()
                if inbox.isComputing { ProgressView().controlSize(.small) }
                Button("Всё прочитано") { inbox.markAllRead(document); inbox.markRepliesSeen() }
                    .controlSize(.small)
                    .help("Запомнить текущий текст как прочитанный: дальше показываются только новые правки")
            }
            Menu {
                ForEach(inbox.baselines) { baseline in
                    Button(label(baseline)) { inbox.select(baseline, document: document) }
                }
            } label: {
                Text("Сравнить с: " + (inbox.baseline.map(label) ?? "нет копии"))
                    .font(.system(size: 11)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(inbox.baselines.isEmpty)
            if let error = inbox.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func label(_ baseline: StudioInbox.Baseline) -> String {
        let date = baseline.date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        return baseline.kind == .seen ? "прочитано \(date)" : "до прохода \(date)"
    }

    // MARK: - Sections

    private func sectionHeader(_ key: String, _ title: String, count: Int, systemImage: String,
                               @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 6) {
            Button {
                toggleCollapsed(key)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isCollapsed(key) ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).frame(width: 10)
                    Image(systemName: systemImage)
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if count > 0 {
                        Text("\(count)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            trailing()
        }
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ViewBuilder
    private var changesSection: some View {
        let changes = inbox.changes
        let removals = inbox.removals
        Section {
            if !isCollapsed("changes") {
                if changes.isEmpty && removals.isEmpty {
                    empty(inbox.baseline == nil ? "Нет копии для сравнения" : "Без новых правок")
                }
                ForEach(groups(changes), id: \.section) { group in
                    Text(group.section ?? "Начало документа")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1).padding(.top, 4)
                    ForEach(group.items) { change in changeRow(change) }
                }
                if !removals.isEmpty {
                    Text("Удалено").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 6)
                    ForEach(removals) { removal in removalRow(removal) }
                }
            }
        } header: {
            sectionHeader("changes", "Правки в документе", count: changes.count + removals.count, systemImage: "pencil.line")
        }
    }

    private func groups(_ changes: [StudioInbox.Change]) -> [(section: String?, items: [StudioInbox.Change])] {
        var result: [(section: String?, items: [StudioInbox.Change])] = []
        for change in changes {
            if let last = result.last, last.section == change.section { result[result.count - 1].items.append(change) }
            else { result.append((change.section, [change])) }
        }
        return result
    }

    private func changeRow(_ change: StudioInbox.Change) -> some View {
        let block = document.blocks.first { $0.id == change.blockID }
        let snippet = block.map { plain(document.displayMarkdown(for: $0)) } ?? plain(change.text)
        return Button { onRevealChange(change) } label: {
            HStack(alignment: .top, spacing: 6) {
                Text("📝")
                Text(snippet).font(.system(size: 12)).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .rowStyle()
        }
        .buttonStyle(.plain)
        .help("Показать правку в документе")
    }

    private func removalRow(_ removal: StudioInbox.Removal) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(plain(removal.text)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                .strikethrough(color: .secondary.opacity(0.4))
                .frame(maxWidth: .infinity, alignment: .leading)
            seenButton { inbox.markSeen(removal) }
        }
        .rowStyle()
        .onTapGesture { if let id = removal.nearBlockID { onReveal(id) } }
        .help(removal.section.map { "Был в разделе «\($0)»" } ?? "Удалённый абзац")
    }

    @ViewBuilder
    private var questionsSection: some View {
        let questions = inbox.openQuestions
        let unplaced = questions.filter { inbox.questionBlocks[$0.number] == nil }
        Section {
            if !isCollapsed("questions") {
                if questions.isEmpty { empty("Открытых вопросов нет") }
                ForEach(questions.filter { inbox.questionBlocks[$0.number] != nil }) { question in
                    Button { onRevealQuestion(question.number) } label: {
                        Text("Q\(question.number) · " + plain(question.text))
                            .font(.system(size: 12)).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .rowStyle()
                    }
                    .buttonStyle(.plain)
                    .help("Показать вопрос в документе")
                }
                if !unplaced.isEmpty {
                    Text("Без привязки").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    ForEach(unplaced) { question in questionCard(question) }
                }
            }
        } header: {
            sectionHeader("questions", "Вопросы секретаря", count: questions.count, systemImage: "questionmark.bubble")
        }
    }

    @ViewBuilder
    private var answeredSection: some View {
        let questions = inbox.answeredQuestions
        if !questions.isEmpty {
            Section {
                if !isCollapsed("answered") {
                    ForEach(questions) { question in questionCard(question, answered: true) }
                }
            } header: {
                sectionHeader("answered", "Отвеченные", count: questions.count, systemImage: "checkmark.bubble")
            }
        }
    }

    private func questionCard(_ question: StudioInbox.Question, answered: Bool = false) -> some View {
        StudioQuestionCard(inbox: inbox, question: question, answered: answered,
                           onOpenSource: onOpenSource, onAnswered: onAnswered,
                           onReveal: inbox.questionBlocks[question.number].map { block in { onReveal(block) } })
    }

    @ViewBuilder
    private var repliesSection: some View {
        let replies = inbox.unreadReplies(in: threads)
        let waiting = inbox.waiting(in: threads)
        Section {
            if !isCollapsed("replies") {
                if replies.isEmpty && waiting.isEmpty { empty("Новых ответов нет") }
                ForEach(replies) { thread in threadRow(thread, reply: thread.replies.last { $0.author != DocumentCommentAuthor.owner }) }
                if !waiting.isEmpty {
                    Text("Ждут секретаря").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
                    ForEach(waiting) { thread in threadRow(thread, reply: nil) }
                }
            }
        } header: {
            sectionHeader("replies", "Комментарии", count: replies.count, systemImage: "text.bubble") {
                if !replies.isEmpty {
                    Button("Прочитано") { inbox.markRepliesSeen() }.controlSize(.mini)
                }
            }
        }
    }

    private func threadRow(_ thread: DocumentCommentThread, reply: DocumentCommentRecord?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                Text(thread.root.reaction ?? "💬")
                VStack(alignment: .leading, spacing: 2) {
                    if let heading = thread.root.heading { Text(heading).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    if let text = thread.root.text, !text.isEmpty { Text(text).font(.system(size: 12)).lineLimit(3) }
                    else if let quote = thread.root.quote { Text("“\(quote)”").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            if let reply, let text = reply.text {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    Text(text).font(.system(size: 11)).lineLimit(4)
                }
                .padding(.leading, 20)
            }
        }
        .rowStyle()
        .onTapGesture { onRevealThread(thread) }
        .help("Показать в документе")
    }

    @ViewBuilder
    private var passesSection: some View {
        Section {
            if !isCollapsed("passes") {
                if inbox.passes.isEmpty { empty("Журнал проходов пуст") }
                ForEach(inbox.passes.prefix(15)) { pass in passRow(pass) }
            }
        } header: {
            sectionHeader("passes", "Проходы секретаря", count: 0, systemImage: "clock.arrow.circlepath")
        }
    }

    private func passRow(_ pass: StudioInbox.Pass) -> some View {
        let expanded = expandedPasses.contains(pass.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(pass.date).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Text(pass.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            Text(pass.summary).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 3)
                .textSelection(.enabled)
                .onTapGesture { if !expandedPasses.insert(pass.id).inserted { expandedPasses.remove(pass.id) } }
            if let id = pass.runID, let backup = inbox.runBackups[id] {
                Button(inbox.baseline == backup ? "Показаны правки с этого прохода" : "Показать правки с этого прохода") {
                    inbox.select(backup, document: document)
                }
                .buttonStyle(.link).font(.system(size: 10))
                .disabled(inbox.baseline == backup)
            }
        }
        .rowStyle()
    }

    // MARK: - Pieces

    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.vertical, 4)
    }

    private func seenButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "checkmark.circle") }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help("Прочитано — убрать из списка")
    }

    private func isCollapsed(_ key: String) -> Bool { collapsedRaw.split(separator: ",").contains(Substring(key)) }
    private func toggleCollapsed(_ key: String) {
        var keys = Set(collapsedRaw.split(separator: ",").map(String.init))
        if !keys.insert(key).inserted { keys.remove(key) }
        collapsedRaw = keys.sorted().joined(separator: ",")
    }
}

private extension View {
    func rowStyle() -> some View {
        padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

private func plain(_ markdown: String, keepCitations: Bool = false) -> String {
    var text = markdown
    if !keepCitations {
        text = text.replacingOccurrences(of: #"\[S\d+(?:,\s*S\d+)*\]"#, with: "", options: .regularExpression)
    }
    for pattern in ["^#+\\s*", "\\*\\*", "(?<!\\w)_|_(?!\\w)", "`"] {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
    return text.split(whereSeparator: \.isNewline).joined(separator: " ")
}


struct StudioQuestionCard: View {
    let inbox: StudioInboxModel
    let question: StudioInbox.Question
    var answered = false
    var inline = false
    let onOpenSource: (String) -> Void
    let onAnswered: (URL) -> Void
    var onReveal: (() -> Void)?

    @State private var expanded = false
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        let showsFullText = inline || expanded || editing
        let draft = Binding(
            get: { inbox.answerDrafts[question.number, default: ""] },
            set: { inbox.answerDrafts[question.number] = $0 }
        )
        VStack(alignment: .leading, spacing: 6) {
            if showsFullText {
                HStack(alignment: .top, spacing: 6) {
                    if expanded && !inline && !editing {
                        Button { expanded = false } label: { questionNumber }
                            .buttonStyle(.plain)
                            .help("Свернуть вопрос")
                    } else {
                        questionNumber
                    }
                    Text(linkedQuestionText)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "wimm-source", let id = url.host,
                                  question.sources.contains(id) else { return .discarded }
                            onOpenSource(id)
                            return .handled
                        })
                }
            } else {
                Button { expanded = true } label: {
                    HStack(alignment: .top, spacing: 6) {
                        questionNumber
                        Text(plain(question.text)).font(.system(size: 12)).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Раскрыть вопрос")
            }
            if !question.sources.isEmpty && !answered && !showsFullText {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(question.sources, id: \.self) { id in
                            Button(id) { onOpenSource(id) }.buttonStyle(.link).font(.system(size: 11))
                                .help("Открыть источник")
                        }
                    }
                }
                .accessibilityLabel("Источники")
            }
            if answered {
                if expanded {
                    Text(inbox.seen.answers?[question.number]?.text ?? "Ответ был сохранён отдельной заметкой.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let onReveal {
                        Button("К абзацу", action: onReveal).buttonStyle(.link).font(.system(size: 11))
                    }
                }
            } else if editing {
                TextField("Ответ на Q\(question.number)", text: draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12)).lineLimit(2...6)
                    .focused($focused)
                    .onAppear { focused = true }
                HStack {
                    Button("Свернуть ответ") { editing = false }.controlSize(.small)
                    Spacer()
                    Button("Сохранить ответ") {
                        if let url = inbox.answer(question, text: draft.wrappedValue) {
                            editing = false
                            onAnswered(url)
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(focused ? .init(.return, modifiers: .command) : nil)
                }
                if let error = inbox.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } else {
                HStack {
                    Spacer()
                    Button(draft.wrappedValue.isEmpty ? "Ответить" : "Продолжить ответ") { editing = true }
                        .controlSize(.small)
                }
            }
        }
        .rowStyle()
    }

    private var questionNumber: some View {
        Text("Q\(question.number)").font(.system(size: 11, weight: .bold)).monospacedDigit()
            .foregroundStyle(answered ? Color.secondary : Color.accentColor)
    }

    private var linkedQuestionText: AttributedString {
        let text = plain(question.text, keepCitations: true)
        let pattern = #/\bS\d+\b/#
        var result = AttributedString()
        var start = text.startIndex
        for match in text.matches(of: pattern) {
            result += AttributedString(String(text[start..<match.range.lowerBound]))
            let id = String(match.output)
            var citation = AttributedString(id)
            if question.sources.contains(id) {
                citation.link = URL(string: "wimm-source://\(id)")
            }
            result += citation
            start = match.range.upperBound
        }
        result += AttributedString(String(text[start...]))
        return result
    }
}


struct StudioChangeCard: View {
    let change: StudioInbox.Change
    let onSeen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(change.kind == .added ? "Добавлено" : "Прежний текст")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let previous = change.previous {
                Text(plain(previous))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button("Прочитано", action: onSeen).controlSize(.small)
        }
        .rowStyle()
    }
}
