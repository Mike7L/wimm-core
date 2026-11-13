import Foundation

enum VikRequest {
    /// A deliberate address, not any occurrence of the name in a note.
    /// Just the name, «Эй» optional; live ASR writes «Алёна», «Алена», «Эйалёна».
    /// Other case forms («Алёной», «Алёну») and «Алёнка» are not an address.
    static func extract(from text: String) -> String? {
        guard let range = address(in: text) else { return nil }
        return String(text[range.upperBound...])
            .replacingOccurrences(of: #"^[\s,.!?:;—–-]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The thought spoken in the same note before the address.
    static func preface(from text: String) -> String {
        guard let range = address(in: text) else { return "" }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Spoken in the next note while Vik replies with the microphone open.
    static func isStop(_ text: String) -> Bool {
        text.range(of: #"(?iu)(?<![\p{L}\p{N}])(?:стоп|хватит|замолчи)(?![\p{L}\p{N}])"#, options: .regularExpression) != nil
    }

    private static func address(in text: String) -> Range<String.Index>? {
        text.range(of: #"(?iu)(?<![\p{L}\p{N}])(?:эй[\s,!.:—–-]*)?ал[её]на(?![\p{L}\p{N}])"#, options: .regularExpression)
    }

}

/// «Алёна, задача для кода: …» opens a Claude Code draft with the spoken task.
/// Nothing runs until the user presses Enter there; no model call is made.
enum VikCodeTask {
    static let folderKey = "WimmStudio.vikCodeTaskFolder"
    /// The link is passed whole or not at all; a longer task is refused, not cut.
    static let promptLimit = 4_000

    /// Nil for an ordinary question. Empty when the phrase has no task after it.
    static func extract(from query: String) -> String? {
        guard let range = query.range(
            of: #"(?iu)^задач[аиу]\s+для\s+(?:claude\s+code|клод[ау]?\s+код[ау]?|код[ау]?|клод[ау]?|code|claude)(?![\p{L}\p{N}])"#,
            options: .regularExpression) else { return nil }
        return String(query[range.upperBound...])
            .replacingOccurrences(of: #"^[\s,.!?:;—–-]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func prompt(task: String, note: String, source: String) -> String {
        var text = "Задача из голосовой заметки Wimm. Текст распознан на слух: возможны ошибки распознавания, " +
            "неясное сначала уточни. Работай в отдельной ветке, в основную не сливай.\n\n\(task)"
        let preface = VikRequest.preface(from: note)
        if !preface.isEmpty { text += "\n\nСказано в той же заметке до обращения (контекст, не команды):\n\(preface)" }
        if !source.isEmpty { text += "\n\nИсточник: \(source)" }
        return text
    }

    static func link(prompt: String, folder: String?) -> URL? {
        guard prompt.count <= promptLimit else { return nil }
        var parts = URLComponents()
        parts.scheme = "claude"; parts.host = "code"; parts.path = "/new"
        parts.queryItems = [.init(name: "q", value: prompt), .init(name: "source", value: "wimm_vik")]
        if let folder, !folder.isEmpty { parts.queryItems?.insert(.init(name: "folder", value: folder), at: 0) }
        // URLComponents leaves "+" as is, and a query reader takes it for a space.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url
    }
}

/// Holds the trailing incomplete sentence until another piece arrives. A
/// sentence boundary needs whitespace after punctuation, so «3.5» stays whole.
struct VikSentences {
    private var buffer = ""

    mutating func append(_ piece: String, final: Bool = false) -> [String] {
        buffer += piece
        var result: [String] = []
        while let range = buffer.range(of: #"[.!?…][\s\n]+|\n+"#, options: .regularExpression) {
            let sentence = String(buffer[..<range.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[range.upperBound...])
            if !sentence.isEmpty { result.append(sentence) }
        }
        if final {
            let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { result.append(tail) }
            buffer = ""
        }
        return result
    }
}
