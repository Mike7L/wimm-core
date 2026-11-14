import Foundation
import WimmInfrastructure

/// One secretary run handed to an outside agent (`docs/Secretary_Dispatcher.md`).
///
/// The contract is files, not stream parsing: Wimm writes `task.md` into
/// `<workspace>/secretary/runs/<id>/`, the agent writes `result.json` there,
/// and Wimm records `run.json` with what it verified itself.
public enum SecretaryRunKind: String, Codable, Sendable {
    /// Pending comment threads only (the `secretary-pass` skill, step 2a).
    case comments
    /// The whole `secretary-pass` skill, started by hand: pending threads,
    /// then new and changed Wimm notes into the document, registry and marks.
    case pass

    /// Wimm note tools the agent may call. Bookkeeping writes belong to Wimm.
    public var wimmTools: [String] {
        let read = ["search_notes", "get_note", "recent_notes", "secretary_review_document"]
        switch self {
        case .comments: return read
        case .pass: return read + ["changed_notes", "marked_notes"]
        }
    }

    /// Page cap for the `wimm` listings: every page stays in the context of
    /// every later turn, and a pass reads a handful of notes per page anyway.
    public static let mcpPageLimit = 20

    /// Environment of the `wimm` MCP server a run starts.
    public var mcpEnvironment: [String: String] {
        [MCPRecallServer.pageLimitEnvironmentKey: String(Self.mcpPageLimit),
         MCPRecallServer.toolsEnvironmentKey: wimmTools.joined(separator: ",")]
    }

    /// Ceiling on agent turns (Claude counts one per tool call): a stuck loop,
    /// not a budget. Runs on 26.10 took 18–21; the one whole-document rewrite
    /// took 291 (`docs/Secretary_Dispatcher.md` §8) and needs `--max-turns`.
    public var maxTurns: Int {
        switch self {
        case .comments: return 100
        case .pass: return 300
        }
    }
}

/// The `_ME`-style workspace a document lives in: a root with a `secretary/` folder.
public struct SecretaryWorkspace: Sendable, Equatable {
    public let root: URL
    public let document: URL
    /// The document's path relative to the root (the `doc` of its comment records).
    public let doc: String
    public let threadsFile: URL

    /// `nil` when the document is not inside a workspace with a `secretary/`
    /// folder: comments then live beside the document and no agent has a
    /// protocol to follow.
    public init?(document: URL) {
        let location = DocumentCommentLocation(document: document)
        let secretary = location.fileURL.deletingLastPathComponent()
        guard location.fileURL.lastPathComponent == "threads.jsonl", secretary.lastPathComponent == "secretary" else { return nil }
        root = secretary.deletingLastPathComponent().standardizedFileURL
        self.document = document.standardizedFileURL
        doc = location.doc
        threadsFile = location.fileURL
    }

    public var runsDirectory: URL { root.appendingPathComponent("secretary/runs", isDirectory: true) }
    public func runDirectory(_ id: String) -> URL { runsDirectory.appendingPathComponent(id, isDirectory: true) }
    /// The protocol is split into a core (`secretary/README.md`) and parts
    /// under `secretary/protocol/`; a task names only the parts it needs.
    public var hasProtocolParts: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent("secretary/protocol/comments.md").path)
    }
    public var managedProtocolPath: String? {
        ["secretary/protocol/managed-review.md", "secretary/protocol/managed.md"].first { path in
            (try? root.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }
    public var hasManagedProtocol: Bool { managedProtocolPath != nil }
    /// Path of a file inside the workspace, relative to the root.
    public func relative(_ url: URL) -> String {
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// What the agent is asked to do, rendered as `task.md`.
public struct SecretaryTask: Sendable {
    public let id: String
    public let kind: SecretaryRunKind
    public let workspace: SecretaryWorkspace
    public let threads: [DocumentCommentThread]
    /// Absolute path of the Wimm CLI the agent calls for `comments`.
    public let wimmCLI: String
    public let createdAt: Date
    public let protocolPath: String?
    public let packetMode: Bool
    public var usesSourceDecisions: Bool { packetMode || protocolPath == "secretary/protocol/managed-review.md" }

    public init(id: String, kind: SecretaryRunKind, workspace: SecretaryWorkspace,
                threads: [DocumentCommentThread], wimmCLI: String, createdAt: Date, packetMode: Bool = false) {
        self.id = id; self.kind = kind; self.workspace = workspace
        self.threads = threads; self.wimmCLI = wimmCLI; self.createdAt = createdAt
        self.protocolPath = workspace.managedProtocolPath
        self.packetMode = packetMode
    }

    public var runDirectory: String { "secretary/runs/\(id)" }
    public var resultPath: String { "\(runDirectory)/result.json" }

    /// The whole prompt an agent gets; the rules themselves stay in the workspace.
    public var prompt: String {
        "Выполни задачу секретаря из файла \(runDirectory)/task.md по правилам AGENTS.md этого каталога. "
            + "Итог запиши в \(resultPath) в формате, описанном в задаче, и закончи одной-двумя фразами по-русски."
    }

    public func markdown() -> String {
        if packetMode {
            return """
            # Пакетный проход Wimm

            Прогон: \(id). Документ: \(workspace.doc).
            Wimm читает semantic policy secretary/protocol/packet.md, выбирает полные версии источников и собирает связанные блоки документа.
            Модель получает packet-1/input.json на stdin без файловых инструментов и MCP, возвращает решения и замены блоков.
            Допускается один запрос дополнительного контекста в packet-2/. До полного результата правки и отметки не применяются.
            Wimm проверяет версии, сохраняет резервные копии и result.json, применяет правки и ведёт реестр/отметки/границу.
            Для обычного редакторского прохода: --workflow agent.
            """
        }
        let document = workspace.document.path
        var lines: [String] = [
            kind == .pass ? "# Задача секретаря: секретарский проход" : "# Задача секретаря: комментарии в документе",
            "",
            "- Прогон: `\(id)`, создан \(SecretaryClock.stamp(createdAt)). Запустил Wimm, Михаил сейчас не в разговоре — вопросы задавать только ответом в треде.",
            "- Документ: `\(workspace.doc)`",
            "- Тредов ждут секретаря: \(threads.count)",
            "",
            "## Что сделать",
            "",
        ]
        lines.append("Каждый разбираемый источник читать через get_note с full: true: усечённый вывод и наличие вариантов на диске не доказывают прочтение. ASR quality — эвристические предупреждения; отсутствие флагов и высокий confidence не гарантируют правильности. Облачную перерасшифровку автоматически не запускать.")
        lines.append("Markdown OCR — непроверенная реконструкция, а не достоверная вёрстка. Сопоставляй его с raw OCR и геометрией; не принимай автоматически связи ячеек, денежные суммы в поле числа платежей или даты в поле суммы. Состояния флажков неизвестны, если явно не извлечены. Оригиналы изображений не запрашивать, не читать через файлы и не передавать модели: они могут быть приватными и дорогими. Если существенный ответ требует просмотра таблицы, рукописи или отметки, оставь источник pending с краткой причиной и продолжай с остальными. Просмотр оригинала требует отдельного явного указания пользователя вне этого прохода. Текстовая квитанция не доказывает просмотра картинки. Поданная картинка тоже не доказывает правильности её понимания.")
        lines.append("Изображения читать по всем блокам evidence и доступной истории, как варианты транскрипций: literal OCR, native scene/observations, barcodes, detected data, MLX description и диагностика относятся к указанному файлу и запуску. MLX description — черновая интерпретация модели, не слова пользователя и не буквальный текст изображения; native observations и detected data тоже могут ошибаться. Отсутствие подписи или проверки означает неизвестность. Не выводить из подписей личность, место, дату или намерение без отдельного источника. Подписи преимущественно английские: для поиска использовать также английские формулировки. get_note не запускает MLX автоматически.")
        let skill = "`.claude/skills/secretary-pass/SKILL.md`"
        if let protocolPath {
            lines += ["Прочитать только `\(protocolPath)` и `\(runDirectory)/context.json`. Это оперативный протокол для запуска Wimm; "
                + "полные README/скилл/части протокола читать только при конкретной неясности. В context.json — только сводка реестра и следующий S-номер. Оглавление с номерами строк лежит отдельно в document-outline.txt; искать в нём нужную тему, целиком не читать."]
            if kind == .pass {
                if usesSourceDecisions {
                    lines += ["Сначала перечисленные треды, затем заметки: `changed_notes` с `since: \"last_pass\"`, `skip_unchanged_marked: true`, "
                        + "`marked_changes: \"transcript,edited\"`, `order: \"newest_first\"`, `limit: 20`; order повторять с курсором. "
                        + "Отмеченные источники со сменой текста пересмотреть, новые добавить. Каждую разобранную заметку читать через get_note. По старым источникам вернуть source_decisions: {source: S-номер, status, reason, при duplicate merged_with: [S-номера]}. Не переписывать хеши и историю.",
                        "Реестр целиком не выводить. Найти нужные записи командой ниже по S-номеру или имени файла из get_note; новый источник проверять по точному имени .meta.json: matched=0. Поисковый --query не доказывает отсутствие источника. "
                        + "Для новых записей entries.json хранить в `\(runDirectory)/`; `python3 secretary/tools/me_registry.py add \(runDirectory)/entries.json --method \"…\" --append-refs` "
                        + "назначит S-номера, хеши и ссылки. Существующие записи реестра не редактировать, даже Python-скриптом: Wimm применит source_decisions и сохранит остальные поля/историю. Только S-номера новых записей после add включить в reviewed_sources.",
                        "Записать короткий итог в change_log.md. Wimm обновит старые записи, хеши, историю, счётчики, определения использованных [S…], отметки и границу. Полную проверку не запускать: до применения решений она показывает ожидаемые расхождения. marks/check/mark_notes/set_pass_boundary не выполнять; ссылки [S…] в тексте оставлять, их отсутствующие определения добавит Wimm."]
                } else {
                    lines += ["Сначала перечисленные треды, затем заметки: `changed_notes` с `since: \"last_pass\"`, `skip_unchanged_marked: true`, "
                        + "`marked_changes: \"transcript,edited\"`, `order: \"newest_first\"`, `limit: 20`; order повторять с курсором. "
                        + "Отмеченные источники со сменой текста пересмотреть, новые добавить. Каждую разобранную заметку читать через get_note и включить её S-номер в reviewed_sources.",
                        "Реестр целиком не выводить. Найти нужные записи командой ниже по S-номеру или имени файла из get_note; новый источник проверять по точному имени .meta.json: matched=0. Поисковый --query не доказывает отсутствие источника. "
                        + "Для новых записей entries.json хранить в `\(runDirectory)/`; `python3 secretary/tools/me_registry.py add \(runDirectory)/entries.json --method \"…\" --append-refs` "
                        + "назначит S-номера, хеши и ссылки. Старые записи править адресно, сохраняя невыведенные поля и историю; весь JSON можно обрабатывать программно, но не печатать в контекст.",
                        "Записать короткий итог в change_log.md. Wimm сам проверит реестр и версии заметок, запишет отметки и границу; marks/check/mark_notes/set_pass_boundary не выполнять."]
                }
            } else {
                lines += ["Разобрать только перечисленные треды; заметки читать лишь для ответа на них. Новые заметки, отметки и границу не трогать. Одна строка в change_log.md."]
            }
        } else {
            switch kind {
            case .comments:
                lines.append("Разобрать только перечисленные ниже треды по разделу «Комментарии Михаила в документе» протокола `secretary/README.md` "
                    + "(скилл \(skill), шаг 2а, затем шаги 9–10: одна строка в `secretary/change_log.md`). Новые заметки не разбирать, границу прохода и отметки Wimm не трогать.")
                if workspace.hasProtocolParts {
                    lines += ["", "Прочитать только ядро `secretary/README.md`, `secretary/protocol/comments.md` и `secretary/protocol/document.md`; "
                        + "остальные части протокола и скилл для этой задачи не нужны."]
                }
            case .pass:
                lines.append("Полный секретарский проход по протоколу `secretary/README.md` и скиллу \(skill), шаги 1–10: "
                    + (threads.isEmpty ? "открытых тредов нет; " : "сначала перечисленные ниже треды (шаг 2а), затем ")
                    + "новые и изменившиеся заметки Wimm (`changed_notes` с `since: \"last_pass\"`, `skip_unchanged_marked: true`, `marked_changes: \"transcript,edited\"` (отмеченные заметки, у которых изменился лишь анализ, пропускать), `order: \"newest_first\"` — с самых свежих, `limit: \(SecretaryRunKind.mcpPageLimit)` (больше сервер не отдаёт), `order` повторять с каждым курсором; `marked_notes`), встраивание в документ, "
                    + "реестр через `python3 secretary/tools/me_registry.py add`, строка в `secretary/change_log.md`. Рабочие файлы (`entries.json`) — в `\(runDirectory)/`, не в scratchpad.")
                lines += ["", "Служебные шаги выполняет Wimm после твоего ответа: запись отметок, сверка реестра/ссылок/отметок и продвижение границы. "
                    + "Не выполнять `me_registry.py marks` / `me_registry.py check`, `mark_notes` и `set_pass_boundary`. "
                    + "Для каждой действительно разобранной карточки прочитать `get_note`, обновить её статус и причину в реестре и включить её S-номер в `reviewed_sources` результата "
                    + "(в том числе при сохранении прежнего pending). Wimm сам хранит версии прочитанных заметок; хеши и отметки переписывать не нужно. "
                    + "Не включать непрочитанные карточки со страницы списка. Если заметка изменилась после чтения, Wimm оставит её следующему проходу. "
                    + "Эти правила заменяют служебные шаги 7–9 скилла; смысловые правила протокола сохраняются."]
                if workspace.hasProtocolParts {
                    lines += ["", "Читать ядро `secretary/README.md`, скилл и части протокола из его шага 1 (`secretary/protocol/comments.md`, `document.md`, `registry.md`); "
                        + "`secretary/protocol/routine.md` (вики, review, расписание) для прохода не нужен."]
                }
            }
        }
        lines += [
            "",
            "Команды — абсолютным путём, без переменных оболочки и без `&&`/`;` (иначе их не пропустят ограничения прогона):",
            "",
            "```bash",
            "\(wimmCLI) comments list \(document) --pending",
            "\(wimmCLI) comments reply \(document) <id> --text \"…\" --status applied",
            "\(wimmCLI) comments status \(document) <id> resolved",
        ]

        if protocolPath != nil {
            lines += ["\(wimmCLI) secretary registry \(document) --source S123",
                      "\(wimmCLI) secretary registry \(document) --file <имя-файла> --limit 20"]
        }
        lines += [
            "```",
            "",
            "## Треды",
            "",
        ]
        if threads.isEmpty { lines.append("Нет.") }
        for thread in threads {
            let what = thread.root.reaction.map { reaction in
                "\(reaction) \(thread.root.intent.flatMap(DocumentReaction.init(rawValue:))?.instruction ?? "")"
            } ?? "комментарий"
            lines.append("- `\(thread.id)` · \(what) · \(thread.root.heading ?? thread.root.section ?? "—")")
            lines.append("  - цитата: «\(Self.oneLine(thread.root.quote ?? "", limit: 240))»")
            if let text = thread.root.text, !text.isEmpty { lines.append("  - Михаил: \(Self.oneLine(text, limit: 600))") }
            for reply in thread.replies where reply.kind == .reply {
                lines.append("  - \(reply.author): \(Self.oneLine(reply.text ?? "", limit: 600))")
            }
        }
        lines += [
            "",
            "## Ограничения",
            "",
            "- Менять можно только файлы в `docs/` и `secretary/`; `recordings/`, `wiki/` и файлы Wimm не трогать"
                + (kind == .pass ? " (заметки Wimm не править; отметки и границу записывает Wimm после прогона)." : "."),
            "- Строки `secretary/threads.jsonl` не править руками — только командами выше.",
            "- Не коммитить. Перед прогоном Wimm сохранил копию документа в `docs/.backups/`.",
            "",
            "## Итог: `\(resultPath)`",
            "",
            "```json",
            "{\"summary\": \"что сделано, по-русски, 1–3 фразы\",",
            " \"threads\": [{\"id\": \"c-…\", \"action\": \"applied | answered | resolved | dropped | skipped\", \"note\": \"коротко\"}],",
            " \"reviewed_sources\": [],",
            " \"source_decisions\": [],",
            " \"changed_files\": [\"docs/…\"],",
            " \"checks\": [{\"name\": \"перечитал изменённые абзацы\", \"ok\": true}],",
            " \"questions\": [\"вопрос Михаилу, если остался\"]}",
            "```",
            "",
            "Каждый тред из списка — в `threads`; `skipped` — только с причиной в `note`.",
        ]
        if !packetMode {
            lines += ["", "## Проверка окончательных правок", "После последней правки документа вызови MCP secretary_review_document с page: 0 и прочитай все страницы (page — с нуля). Он показывает удалённый и новый текст с контекстом. Любая следующая правка требует повторного чтения всех страниц. Wimm проверяет покрытие окончательной версии; checks в result.json — только твой отчёт, не доказательство проверки."]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// What the agent reports in `result.json`. Every field is optional: a missing
/// or partial result is a finding, never a crash.
public struct SecretaryResult: Codable, Sendable, Equatable {
    public struct ThreadOutcome: Codable, Sendable, Equatable {
        public var id: String
        public var action: String?
        public var note: String?
    }
    public struct SourceDecision: Codable, Sendable, Equatable {
        public var source: String
        public var status: String
        public var reason: String
        public var mergedWith: [String]?
        enum CodingKeys: String, CodingKey {
            case source, status, reason
            case mergedWith = "merged_with"
        }
    }
    public struct Check: Codable, Sendable, Equatable {
        public var name: String
        public var ok: Bool?
        public var detail: String?

        public init(name: String, ok: Bool? = nil, detail: String? = nil) {
            self.name = name; self.ok = ok; self.detail = detail
        }

        /// Some agents return descriptive strings in checks. They are diagnostics,
        /// not successful verification; Wimm still performs its own checks.
        public init(from decoder: Decoder) throws {
            if let description = try? decoder.singleValueContainer().decode(String.self) {
                self.init(name: description)
            } else {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                self.init(name: try values.decode(String.self, forKey: .name),
                          ok: try values.decodeIfPresent(Bool.self, forKey: .ok),
                          detail: try values.decodeIfPresent(String.self, forKey: .detail))
            }
        }
    }
    public var summary: String?
    /// Source IDs actually reviewed; get_note versions are recorded by Wimm, not copied by the model.
    public var reviewedSources: [String]?
    public var sourceDecisions: [SourceDecision]?
    public var threads: [ThreadOutcome]?
    public var changedFiles: [String]?
    public var checks: [Check]?
    public var questions: [String]?

    enum CodingKeys: String, CodingKey {
        case summary, threads, checks, questions
        case reviewedSources = "reviewed_sources"
        case sourceDecisions = "source_decisions"
        case changedFiles = "changed_files"
    }
}

/// `run.json`: what Wimm saw and checked, independent of the agent's own account.
public struct SecretaryRunRecord: Codable, Sendable, Equatable {
    public enum Outcome: String, Codable, Sendable { case succeeded, incomplete, failed, cancelled }

    public var id: String
    public var kind: SecretaryRunKind
    public var doc: String
    public var executor: String
    public var model: String?
    public var workflow: String? = nil
    public var threadIDs: [String]
    public var startedAt: String
    public var finishedAt: String?
    public var outcome: Outcome?
    public var exitStatus: Int32?
    public var costUSD: Double?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var turns: Int?
    public var sessionID: String?
    /// Workspace-relative path of the document copy taken before the run.
    public var backup: String?
    /// The agent's closing message.
    public var finalText: String?
    public var result: SecretaryResult?
    /// Deterministic verification findings; empty means every check passed.
    public var bookkeeping: SecretaryBookkeepingReport?
    public var findings: [String] = []
    /// Host scan after bookkeeping, not the agent’s estimate; nil means unknown.
    public var remainingNotes: Int?
    /// Notes put back into the queue because an applied edit removed their references.
    public var requeuedNotes: [String]?
    /// Sources the packet kept out: waiting for text, waiting for viewing, skipped.
    public var hostQueues: SecretaryHostQueues? = nil
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, doc, executor, model, workflow, outcome, backup, result, findings, error, turns, bookkeeping
        case threadIDs = "thread_ids", startedAt = "started_at", finishedAt = "finished_at"
        case exitStatus = "exit_status", costUSD = "cost_usd", tokensIn = "tokens_in", tokensOut = "tokens_out"
        case sessionID = "session_id", finalText = "final_text", remainingNotes = "remaining_notes", requeuedNotes = "requeued_notes"
        case hostQueues = "host_queues"
    }
}

public enum SecretaryError: LocalizedError, Equatable {
    case notAWorkspace(String)
    case nothingToDo
    case privateMode
    case unsupportedPlatform
    case busy(String)
    case executorMissing(String)
    case wimmCLIMissing
    /// The CLI lacks what the task relies on (an old copy); nothing was started.
    case wimmCLIStale(String, [String])

    public var errorDescription: String? {
        switch self {
        case .notAWorkspace(let path): "\(path) is not inside a workspace with a secretary/ folder."
        case .nothingToDo: "Nothing is waiting for the secretary: no open comment threads and no new or changed notes."
        case .privateMode: "Private mode is on: an outside agent would read the document unmasked, so secretary runs are off."
        case .unsupportedPlatform: "Secretary runs require macOS and cannot launch an external agent on this platform."
        case .busy(let run): "Another secretary run is in progress (\(run))."
        case .executorMissing(let name): "\(name) was not found. Install it or set its path."
        case .wimmCLIMissing: "The Wimm CLI (WimmCLI.app or ~/.local/share/wimm/WimmCLI) was not found."
        case .wimmCLIStale(let path, let missing):
            "The Wimm CLI at \(path) is too old for this run (missing: \(missing.joined(separator: ", "))). "
                + "Rebuild it (scripts/make_cli.sh -i) or point WIMM_CLI_PATH at a current build."
        }
    }
}

enum SecretaryClock {
    static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// `20261025-183012-3fa9`: sortable, readable, unique enough for one workspace.
    static func runID(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + String(UUID().uuidString.lowercased().prefix(4))
    }
}

/// One run at a time per workspace: `secretary/runs/.lock`, created
/// exclusively. A lock whose process is gone is stale and taken over.
public struct SecretaryRunLock: Sendable {
    public let url: URL

    public static func acquire(in runsDirectory: URL, runID: String) throws -> SecretaryRunLock {
        try FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        let url = runsDirectory.appendingPathComponent(".lock")
        let body = Data("{\"pid\":\(getpid()),\"run\":\"\(runID)\"}\n".utf8)
        for _ in 0..<2 {
            let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                _ = body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                close(fd)
                return SecretaryRunLock(url: url)
            }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let holder = Self.holder(of: url)
            if let pid = holder.pid, kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            throw SecretaryError.busy(holder.run ?? "unknown")
        }
        throw SecretaryError.busy("unknown")
    }

    public func release() { try? FileManager.default.removeItem(at: url) }

    static func holder(of url: URL) -> (pid: pid_t?, run: String?) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, nil) }
        return ((object["pid"] as? NSNumber).map { pid_t($0.int32Value) }, object["run"] as? String)
    }
}

/// What the workspace looked like before the run, for the checks after it.
struct SecretarySnapshot: Sendable {
    let threads: Data
    /// Dirty paths (git status) and their modification dates; `nil` outside git.
    let dirty: [String: Date]?

    static func take(_ workspace: SecretaryWorkspace) -> SecretarySnapshot {
        SecretarySnapshot(threads: (try? Data(contentsOf: workspace.threadsFile)) ?? Data(),
                          dirty: SecretaryGit.dirtyPaths(in: workspace.root))
    }
}

enum SecretaryGit {
    /// Paths `git status` reports as changed or untracked, with their dates.
    static func dirtyPaths(in root: URL) -> [String: Date]? {
        #if os(macOS)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var paths: [String: Date] = [:]
        var entries = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        while let entry = entries.popFirst() {
            guard entry.count > 3 else { continue }
            let status = entry.prefix(2)
            let path = String(entry.dropFirst(3))
            // A rename carries its old path as the next entry.
            if status.contains("R") || status.contains("C") { _ = entries.popFirst() }
            let date = (try? root.appendingPathComponent(path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            paths[path] = date ?? .distantPast
        }
        return paths
        #else
        return nil
        #endif
    }
}

/// Deterministic checks after a run. They never change anything.
enum SecretaryVerification {
    static let allowedPrefixes = ["docs/", "secretary/"]

    static func findings(task: SecretaryTask, before: SecretarySnapshot, after: SecretarySnapshot,
                         result: SecretaryResult?, resultError: String?) -> [String] {
        var findings: [String] = []
        if let resultError { findings.append(resultError) }

        // The threads file is append-only: what was there must still be its start.
        if after.threads.count < before.threads.count || after.threads.prefix(before.threads.count) != before.threads {
            findings.append("secretary/threads.jsonl was rewritten, not appended to.")
        } else {
            let handled = repliedThreadIDs(in: after.threads.suffix(from: before.threads.count))
            let skipped = Set((result?.threads ?? []).filter { $0.action == "skipped" }.map(\.id))
            let unhandled = task.threads.map(\.id).filter { !handled.contains($0) && !skipped.contains($0) }
            if !unhandled.isEmpty { findings.append("Threads left without a reply or status: \(unhandled.joined(separator: ", ")).") }
        }

        if let old = before.dirty, let new = after.dirty {
            let touched = Set(new.filter { old[$0.key] != $0.value }.map(\.key))
                .union(old.keys.filter { new[$0] == nil })
            let outside = touched.filter { path in !allowedPrefixes.contains { path.hasPrefix($0) } }.sorted()
            if !outside.isEmpty { findings.append("Changed outside docs/ and secretary/: \(outside.joined(separator: ", ")).") }
        }

        for check in result?.checks ?? [] where check.ok == false {
            findings.append("Agent check failed: \(check.name)\(check.detail.map { " — \($0)" } ?? "").")
        }
        return findings
    }

    static func repliedThreadIDs(in appended: Data) -> Set<String> {
        let decoder = JSONDecoder()
        var ids = Set<String>()
        for line in appended.split(separator: UInt8(ascii: "\n")) {
            if let record = try? decoder.decode(DocumentCommentRecord.self, from: Data(line)),
               record.kind == .reply || record.kind == .status, let target = record.replyTo {
                ids.insert(target)
            }
        }
        return ids
    }
}
