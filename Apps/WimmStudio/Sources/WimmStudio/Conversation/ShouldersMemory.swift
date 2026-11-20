import Foundation
import WimmDomain
import WimmInfrastructure

/// What the angel and the demon remember between conversations: promises,
/// decisions, the score, running jokes and where the last talk ended.
///
/// The memory is a short text file the user can read and edit
/// (`Conversation/shoulders_memory.md`). It is rewritten by one model call
/// when a conversation opens and earlier transcripts in
/// `Conversation/shoulders/` are not in it yet; the web panel
/// (`server/shouldersMemory.ts`) keeps the same files, keep both in step.
enum ShouldersMemory {
    struct Transcript: Equatable {
        let id: String
        let date: Date
        let text: String
    }

    /// `take` goes to the model, oldest first; `skip` is only marked as seen.
    struct Pending: Equatable {
        var take: [Transcript] = []
        var skip: [String] = []
    }

    /// A first run may find months of transcripts: only the newest are read.
    static let maxConversations = 5
    static let maxCharacters = 60_000

    static var defaultDirectory: URL { FriendConversation.replyURL.deletingLastPathComponent() }

    static func fileURL(in directory: URL) -> URL { directory.appendingPathComponent("shoulders_memory.md") }
    private static func previousURL(in directory: URL) -> URL { directory.appendingPathComponent("shoulders_memory.previous.md") }
    private static func stateURL(in directory: URL) -> URL { directory.appendingPathComponent("shoulders_memory_state.json") }

    /// The memory as the characters get it; nil when there is none yet.
    static func text(in directory: URL = defaultDirectory) -> String? {
        guard let text = try? String(contentsOf: fileURL(in: directory), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func seen(in directory: URL = defaultDirectory) -> Set<String> {
        guard let data = try? Data(contentsOf: stateURL(in: directory)),
              let state = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [] }
        return Set(state["seen"] ?? [])
    }

    /// Finished conversations the memory does not know yet. `current` is the
    /// conversation being opened. A transcript where the user never answered
    /// has nothing to remember and is skipped without a model call.
    /// shortcut: a conversation still running in the other Studio (web vs. native)
    /// is read as it stands and its later turns are not remembered.
    static func pending(excluding current: String, in directory: URL = defaultDirectory) -> Pending {
        let folder = directory.appendingPathComponent("shoulders", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let known = seen(in: directory)
        var pending = Pending()
        var candidates: [Transcript] = []
        for file in files where file.pathExtension == "md" {
            let id = file.deletingPathExtension().lastPathComponent
            guard id != current, !known.contains(id),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            guard hasUserReply(text) else {
                pending.skip.append(id)
                continue
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            candidates.append(Transcript(id: id, date: date, text: text))
        }
        var used = 0
        for transcript in candidates.sorted(by: { ($0.date, $0.id) > ($1.date, $1.id) }) {
            if pending.take.count < maxConversations, used + transcript.text.count <= maxCharacters {
                used += transcript.text.count
                pending.take.append(transcript)
            } else {
                pending.skip.append(transcript.id)
            }
        }
        pending.take.reverse()
        pending.skip.sort()
        return pending
    }

    /// Native transcripts write `**Пользователь…:**`, the web panel `**Ты…:**`.
    static func hasUserReply(_ transcript: String) -> Bool {
        transcript.split(separator: "\n").contains { $0.hasPrefix("**Пользователь") || $0.hasPrefix("**Ты") }
    }

    static func markSeen(_ ids: [String], in directory: URL = defaultDirectory) {
        guard !ids.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let all = seen(in: directory).union(ids).sorted()
            try JSONEncoder().encode(["seen": all]).write(to: stateURL(in: directory), options: .atomic)
        } catch {
            log("[Shoulders] memory state not written: \(error.localizedDescription)")
        }
    }

    /// Replaces the memory (the old text is kept beside it) and marks the conversations it now covers.
    static func store(_ memory: String, covering ids: [String], in directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = fileURL(in: directory), previous = previousURL(in: directory)
        if let old = try? Data(contentsOf: file) { try old.write(to: previous, options: .atomic) }
        try Data((memory + "\n").utf8).write(to: file, options: .atomic)
        markSeen(ids, in: directory)
    }

    // MARK: - Prompts

    static let rewritePrompt = """
    Ты ведёшь память Ангела и Демона — двух персонажей, которые разговаривают с человеком вслух. \
    Ниже их прежняя память (может быть пустой) и новые разговоры с датами. Перепиши память целиком: \
    не длиннее 300 слов, по-русски, простым текстом, строго с этими пятью заголовками.

    Обещал:
    что он сам пообещал или собрался сделать — его словами в кавычках, с датой разговора. \
    Сделанное и отменённое убери.

    Решил:
    выборы, которые он сделал: дата и чья сторона взяла верх.

    Счёт:
    «Ангел N : Демон M». Очко прибавляй, только когда он сам ясно выбрал сторону; иначе счёт не меняй.

    Свои шутки:
    словечки и шутки, которые родились в разговорах и к которым можно вернуться.

    В прошлый раз:
    дата и одна-две фразы о том, на чём остановились.

    Только то, что есть в прежней памяти и в разговорах; ничего не додумывай. Его слова — дословно. \
    В пустом разделе поставь прочерк. Старое и неважное убирай, чтобы уложиться в объём.
    """

    static func rewriteRequest(memory: String?, transcripts: [Transcript]) -> String {
        var parts = ["# Прежняя память\n\n" + (memory ?? "(пусто)")]
        for transcript in transcripts {
            parts.append("# Разговор \(stamp(transcript.date))\n\n" + transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return parts.joined(separator: "\n\n")
    }

    /// The block added to a turn's system prompt.
    static func promptBlock(memory: String, today: Date) -> String {
        """
        # Ваша память о прошлых разговорах

        Сегодня \(day(today)). Ниже ваши заметки о прежних разговорах с ним: так и было. Пользуйтесь ими \
        как старые знакомые — не пересказывайте, а вспоминайте к месту. Если он что-то обещал, спросите, \
        сделал ли. Счёт и свои шутки берите только отсюда и из этого разговора.

        \(memory)
        """
    }

    /// Opens a conversation that has a past; as specific as the first-time opener, which keeps the model from thinking.
    static let opener = "(Пользователь только что открыл окно. Поздоровайтесь и сразу спросите про то, на чём вы остановились в прошлый раз.)"

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    static func day(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
    static func stamp(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: date) }
}
