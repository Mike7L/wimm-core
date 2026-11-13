import Foundation
import WimmDomain
import WimmInfrastructure

/// One model plays both the angel and the demon, straight from Studio, so a
/// turn starts speaking as soon as its first line is written instead of after
/// an outside agent wakes up, thinks and saves a file.
///
/// The personal document is too large to resend every turn, so it is read
/// once into a dossier (cached beside `friend.md` until the document changes);
/// each turn then sends the dossier and the conversation so far.
@MainActor
final class ShouldersChat {
    private let document: URL
    private let chat: GeminiChatStream
    private var dossier: String?
    /// One paid read of the document, however many callers wait for it.
    private var preparing: Task<Void, Error>?
    private var history: [GeminiChatStream.Message] = []
    /// Fixed for the whole conversation: an unchanged system prompt (style +
    /// dossier) is the prefix Gemini caches implicitly, ~60% of each turn's input.
    let style = ShouldersStyle.current
    let conversationId: String
    let conversationRelativeFile: String

    init(document: URL) {
        self.document = document
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = "shoulders_\(formatter.string(from: Date()))"
        self.conversationId = id
        self.conversationRelativeFile = "Conversation/shoulders/\(id).md"
        let selected = ModelSelection.model(for: .understand)
        // The stream speaks Gemini only; any other selected provider falls back to the default Gemini model.
        let model = selected.hasPrefix("gemini") ? selected : ModelSelection.defaultGeminiModel
        chat = GeminiChatStream(model: model, operation: .conversation, origin: "ShouldersChat")
    }

    var isPrepared: Bool { dossier != nil }

    /// Reads the document into the dossier, from the cache when the document is unchanged.
    func prepare() async throws {
        guard dossier == nil else { return }
        if let preparing { return try await preparing.value }
        let task = Task { try await readDocument() }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    private func readDocument() async throws {
        // The dossier is kept until the user asks for a new one: the document
        // changes all day (the secretary edits it) and every re-read is ~100K tokens.
        if let cached = Self.cachedDossier(for: document) {
            dossier = cached
            return
        }
        let document = document
        let text = try await Task.detached { try String(contentsOf: document, encoding: .utf8) }.value
        let made = try await chat.complete(system: Self.dossierPrompt,
                                           messages: [.init(role: .user, text: text)])
        guard !made.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        dossier = made
        Self.storeDossier(made, key: "\(document.path)|\(chat.model)|\(Self.dossierPromptVersion)")
    }

    /// The characters' next turn, line by line as the model writes it. `answer`
    /// is what the user just said; nil opens the conversation.
    /// Call after `prepare()`; without a dossier the characters know only the conversation.
    func turn(answer: String?) -> AsyncThrowingStream<ShoulderLine, Error> {
        // A vague opener ("начните разговор") made the model think 0.2–1.3K tokens and
        // speak after 4–14 s despite thinkingBudget 0; naming the topic: 0 tokens, ~2 s (2026-11-03).
        let said = answer ?? "(Пользователь только что открыл окно. Поздоровайтесь и сразу заговорите о самом свежем из досье.)"
        if history.last?.role == .user {
            // The previous turn was cut off before a word came back: keep both answers.
            history[history.count - 1].text += "\n" + said
        } else {
            history.append(.init(role: .user, text: said))
        }
        let pieces = chat.stream(system: style.prompt + "\n\n# Досье\n\n" + (dossier ?? ""),
                                 messages: history, timeout: 60,
                                 thinking: ShouldersThinking.current.config)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                var buffer = "", previous: ShoulderSpeaker?
                func emit(_ raw: String) {
                    guard let line = ShouldersDialogue.streamedLine(raw, previous: previous) else { return }
                    previous = line.speaker
                    continuation.yield(line)
                }
                do {
                    for try await piece in pieces {
                        buffer += piece
                        while let newline = buffer.firstIndex(of: "\n") {
                            emit(String(buffer[..<newline]))
                            buffer = String(buffer[buffer.index(after: newline)...])
                        }
                    }
                    emit(buffer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What the characters actually said this turn, cut off or not; the next turn builds on it.
    func heard(_ lines: [ShoulderLine]) {
        guard !lines.isEmpty else { return }
        history.append(.init(role: .model, text: lines.map { "\($0.speaker.emoji): \($0.text)" }.joined(separator: "\n")))
        persistTranscript()
    }

    /// Context for the secretary to place a user's spoken reply in the document:
    /// the opening turn (which names the topic) and the latest turn the user answered.
    func placementContext(currentReply: String) -> String {
        let modelTurns = history.filter { $0.role == .model }.map(\.text)
        let latest = currentReply.isEmpty ? (modelTurns.last ?? "") : currentReply
        guard let first = modelTurns.first, first != latest else { return latest }
        return "Начало спора:\n\(first)\n\nХод перед ответом:\n\(latest)"
    }

    func persistTranscript(latestNoteName: String? = nil, latestAnswerText: String? = nil) {
        let url = StoragePaths.baseDirectory().appendingPathComponent(conversationRelativeFile)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var md = "# Ангел и Демон (\(conversationId))\nДокумент: \(document.lastPathComponent)\n\n"
            for msg in history {
                if msg.role == .model {
                    md += msg.text + "\n\n"
                } else if !msg.text.hasPrefix("(") {
                    md += "**Пользователь:** \(msg.text)\n\n"
                }
            }
            if let latestAnswerText, !latestAnswerText.isEmpty {
                let noteTag = latestNoteName.map { " (`\($0)`)" } ?? ""
                md += "**Пользователь\(noteTag):** \(latestAnswerText)\n\n"
            }
            try Data(md.utf8).write(to: url, options: .atomic)
        } catch {
            log("[Shoulders] transcript not written: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompts

    private static let dossierPromptVersion = "1"

    private static let dossierPrompt = """
    Ниже личный документ человека. Двое персонажей, Ангел и Демон, будут разговаривать с ним вслух, \
    и им нужно досье на 1500–2500 слов. Пиши по-русски, простым текстом без таблиц.

    Собери в досье:
    - кто он и чем живёт сейчас;
    - его ценности, принципы и обещания самому себе — по возможности его собственными словами, в кавычках;
    - текущие проекты, открытые решения и то, что он откладывает;
    - его соблазны, слабости и оправдания, которые он сам называет;
    - важные люди (имена как в тексте) и что с ними связано;
    - что недавно изменилось или тревожит.

    Только то, что есть в документе; ничего не додумывай. Цитаты — дословно.
    """

    // MARK: - Dossier cache

    private static var cacheURL: URL {
        FriendConversation.replyURL.deletingLastPathComponent().appendingPathComponent("shoulders_dossier.json")
    }

    /// shortcut: the key's model and prompt version are not checked; after changing the prompt, rebuild from the menu.
    private static func cachedDossier(for document: URL) -> String? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([String: String].self, from: data),
              cached["key"]?.hasPrefix(document.path + "|") == true else { return nil }
        return cached["dossier"]
    }

    /// Sets the current dossier aside (kept, dated) so the next conversation reads the document anew.
    static func setDossierAside() throws {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let aside = cacheURL.deletingLastPathComponent().appendingPathComponent("shoulders_dossier.\(stamp).json")
        try FileManager.default.moveItem(at: cacheURL, to: aside)
    }

    private static func storeDossier(_ dossier: String, key: String) {
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(["key": key, "dossier": dossier]).write(to: cacheURL, options: .atomic)
        } catch {
            log("[Shoulders] dossier not cached: \(error.localizedDescription)")
        }
    }
}

/// How the angel and the demon talk, picked in the Studio menu; a conversation
/// keeps the style it was opened with, a change applies to the next one. Compared side by side on
/// 2026-11-03 (same dossier, same real answers): `original` is the first
/// prompt, `voices` gives each its own manner and a shared history, `listening`
/// adds reacting to how the user answers instead of taking turns.
enum ShouldersStyle: String, CaseIterable, Identifiable {
    case original, voices, listening

    static let defaultsKey = "WimmStudio.shouldersStyle"

    static var current: ShouldersStyle {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .original }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Original"
        case .voices: return "Own Voices"
        case .listening: return "Own Voices, Listening"
        }
    }

    var prompt: String {
        switch self {
        case .original: return Self.originalPrompt
        case .voices: return Self.voicesPrompt + "\n\n" + Self.format + " " + Self.questionEnding
        case .listening: return Self.voicesPrompt + "\n\n" + Self.format + "\n\n" + Self.listeningRules
        }
    }

    private static let originalPrompt = """
    Ты кукловод двух персонажей, которые сидят на плечах у человека и разговаривают с ним вслух.

    😇 Ангел стоит за то, что человек сам считает правильным: опирается на его ценности и обещания \
    из досье. Говорит тепло и коротко, без морали и без «ты должен».
    😈 Демон — искуситель и адвокат дьявола: сиюминутное желание, лень, «а может, ну его», \
    неудобный вопрос, который Ангел обходит. Остроумный, иногда прав. Не толкает к тому, что вредит \
    здоровью, людям или закону, и не высмеивает человека.

    Оба обращаются к человеку на «ты», знают досье и всё сказанное, спорят друг с другом. \
    Конкретные детали бери только из досье и разговора, ничего не выдумывай. Если человек принёс \
    новую тему, идите за ней.

    \(format) \(questionEnding)
    """

    private static let voicesPrompt = """
    Вы — Ангел и Демон. Вы сидите у человека на плечах и говорите с ним вслух.

    😇 Ангел — как старый друг, который помнит его обещания. Любит «помнишь, ты сам говорил…» \
    и цитирует его дословно из досье. Не спорит в лоб, а спрашивает, как он будет себя чувствовать завтра. \
    Тёплый, но не сладкий.
    😈 Демон — обаятельный, ироничный, ленивый. Знает его оправдания по именам и возвращает их ему же. \
    Короткие фразы, любит «да ладно» и «а кто узнает». Иногда неожиданно честен. Не толкает к тому, что \
    вредит здоровью, людям или закону, и не высмеивает человека.

    Вы знаете друг друга давно: старая вражда, свои шутки, счёт побед. Каждый хочет выиграть именно этот \
    выбор. Иногда вы неожиданно соглашаетесь — это сильнее любого спора. Демон иногда прав, и Ангел это \
    признаёт. Оба на «ты». Конкретные детали — только из досье и разговора, ничего не выдумывайте. \
    Если он принёс новую тему, идите за ней.
    """

    private static let format = """
    Формат строго такой — каждая реплика с новой строки, ничего больше:
    😇: текст
    😈: текст

    Ход — 2–5 коротких реплик, каждая не длиннее двух предложений: перепалка, а не две речи. \
    Пишите так, как это звучит вслух: без markdown, списков, ссылок и ремарок.
    """

    private static let questionEnding = """
    Закончи ход вопросом к человеку от того, чья позиция сейчас слабее, — решает он. Если он говорит, \
    что хватит, попрощайтесь одной-двумя репликами без вопроса.
    """

    private static let listeningRules = """
    Слушайте, что он сказал, а не только тему. Если он увиливает, Демон замечает это первым. \
    Если ему тяжело, оба сбавляют тон, Демон тоже. Не каждый ход обязан кончаться вопросом: иногда \
    лучше одна точная фраза. Если он говорит, что хватит, попрощайтесь без вопроса.
    """
}

/// How much the model may think before the characters speak. Read every turn,
/// so it can be changed mid-conversation; the prompt prefix stays cached.
/// 2026-11-03 on `gemini-flash-latest`: none ≈ 2 s to the first line, low 2–6 s.
enum ShouldersThinking: String, CaseIterable, Identifiable {
    case off, low, medium, model

    static let defaultsKey = "WimmStudio.shouldersThinking"

    static var current: ShouldersThinking {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .off }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "No Thinking (fastest)"
        case .low: return "Low"
        case .medium: return "Medium"
        case .model: return "Model Default (slowest)"
        }
    }

    var config: GeminiChatStream.Thinking? {
        switch self {
        case .off: return nil
        case .low: return .lowLevel
        case .medium: return .mediumLevel
        case .model: return .modelDefault
        }
    }
}
