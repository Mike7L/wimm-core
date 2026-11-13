import Foundation

/// The whole packet as plain Markdown pages, so a conversational editor reads files in order
/// instead of parsing input.json with its own scripts. Source evidence is copied whole.
/// Attention notes are taken only from Wimm's own header lines, never from user text.
extension SecretaryPacketFiles {
    static let packetPageBytes = 24_000

    static func packetPages(_ state: State, inlinePolicy: String? = nil) throws -> [String] {
        let packet = try state.packet()
        let input = try JSONSerialization.jsonObject(with: state.input) as? [String: Any] ?? [:]
        var chunks: [(text: String, source: String?)] = []

        var summary = "Документ: \(input["document"] as? String ?? packet.task.workspace.doc)"
        summary += " · источников в порции: \(packet.selected.count)"
        if let remaining = input["remaining"] { summary += " · ждут после этой порции: \(remaining)" }
        if let format = input["response_format"] { summary += " · формат ответа: \(format)" }
        chunks.append(("\(summary)\n\n", nil))

        chunks.append(("## Правила и формат ответа\n\n\((inlinePolicy ?? state.policy).trimmingCharacters(in: .whitespacesAndNewlines))\n\n", nil))

        let documentStart = chunks.endIndex
        let previews = Self.oversizePreviewSections(input)

        if let queue = input["review_queue"] as? String, !queue.isEmpty {
            chunks.append(("## Очередь вопросов (secretary/review_queue.md)\n\n\(queue.trimmingCharacters(in: .whitespacesAndNewlines))\n\n", nil))
        }
        if let outline = input["outline"] as? [[String: Any]], !outline.isEmpty {
            var text = ""
            for row in outline { text += "- `\(row["id"] as? String ?? "")` \(row["title"] as? String ?? "")\n" }
            if input["outline_truncated"] as? Bool == true { text += "\nОглавление обрезано: остальное через `secretary read RUN --outline`.\n" }
            chunks.append(("## Оглавление документа (id блока → заголовок)\n\n\(text.trimmingCharacters(in: .newlines))\n\n", nil))
        }
        if let blocks = input["document_blocks"] as? [[String: Any]], !blocks.isEmpty {
            let legend = "Путь указан один раз для группы блоков. ID раздела подходит для `secretary read RUN --section`. Строка `〔b…〕` открывает блок."
            chunks.append(("## Блоки документа\n\n\(legend)\n\n", nil))
            let sections = sectionLabels(packet.blocks, for: Set(blocks.compactMap { $0["id"] as? String }))
            var previousSection: String?
            for block in blocks {
                let id = block["id"] as? String ?? ""
                let body = block["text"] as? String ?? ""
                let section = sections[id]
                let label = section != previousSection ? section.map { "\($0)\n\n" } ?? "" : ""
                chunks.append(("\(label)〔\(id)〕\n\(body)\n", nil))
                previousSection = section
            }
        }

        var sourceChunks: [(text: String, source: String?)] = []
        for id in packet.selected {
            var text = "===== источник \(id) =====\n"
            let source = packet.fullSourcesByID[id] ?? ""
            text += "\n\(compactSourceHeader(source))\n===== конец источника \(id) =====\n\n"
            sourceChunks.append((text, id))
        }
        chunks.insert(contentsOf: sourceChunks, at: documentStart)

        if packet.selected.isEmpty || inlinePolicy != nil {
            chunks.insert(contentsOf: previews.map { ($0, nil) }, at: documentStart)
        } else if !previews.isEmpty {
            chunks.insert(("Превью крупных источников для отдельной сортировки: `oversize-previews.md`.\n\n", nil), at: 1)
        }
        let header = """
        # Пакет секретаря \(state.id)

        Прочитай файл целиком. Если инструмент обрезал вывод, дочитай оставшиеся строки.

        """
        return [header + "\n" + chunks.map(\.text).joined()]
    }

    /// Use the snapshot's heading order, including ancestors outside the selected context.
    private static func sectionLabels(_ blocks: [SecretaryPacket.Block], for selected: Set<String>) -> [String: String] {
        var headings: [(id: String, depth: Int, title: String)] = []
        var labels: [String: String] = [:]
        for block in blocks {
            if let heading = SecretaryPacket.heading(block.text) {
                while let last = headings.last, last.depth >= heading.depth { headings.removeLast() }
                headings.append((block.id, heading.depth, String(heading.line.dropFirst(heading.depth + 1))))
            }
            if selected.contains(block.id), let section = headings.last {
                let path = headings.map(\.title).joined(separator: " → ")
                labels[block.id] = "Раздел `\(section.id)` · \(path)"
            }
        }
        return labels
    }

    static func oversizePreviewSections(_ state: State) throws -> [String] {
        Self.oversizePreviewSections(try JSONSerialization.jsonObject(with: state.input) as? [String: Any] ?? [:])
    }

    private static func oversizePreviewSections(_ input: [String: Any]) -> [String] {
        guard let previews = input["oversize_previews"] as? [[String: Any]], !previews.isEmpty else { return [] }
        return ["## Превью крупных источников\n\nТолько начало и конец. Допустимо отметить `not_a_note` или пропустить.\n\n"] +
            previews.compactMap { row in
                guard let id = row["source"] as? String, let head = row["head"] as? String,
                      let tail = row["tail"] as? String else { return nil }
                return "### \(id) · \(row["file"] ?? "") · \(row["total_bytes"] ?? "") Б\n\nНачало\n\n\(head)\n\nКонец\n\n\(tail)\n\n"
            }
    }

    static func compactSourceHeader(_ source: String) -> String {
        let headerCount = headerLines(source).count
        let suffix = " default status blocks omitted (empty barcodes/detected data, no layout record, no MLX description, no diagnostic issues); visual accuracy unverified"
        return source.components(separatedBy: "\n").enumerated().compactMap { index, line in
            guard index < headerCount else { return line }
            if line.hasPrefix("device: ") || line.hasPrefix("mark: ") ||
                line == "text_scope: all_available_text" ||
                line == "refined: unedited fallback copy; every word appears in the text below, omitted" {
                return nil
            }
            if line.hasPrefix("image_status: "), line.hasSuffix(suffix) {
                return String(line.dropLast(suffix.count)) + " default image statuses omitted; visual accuracy unverified"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Exported files are read by an outside agent and stay on disk: key-like strings
    /// (`GEMINI_API_KEY=AIza…` on IDE screenshots, 2026-11-04) keep only a short prefix.
    /// Receipts still cover the unmasked text Wimm read.
    static func masked(_ text: String) -> String {
        var text = text
        for (pattern, template) in secretPatterns {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.stringByReplacingMatches(in: text, range: range, withTemplate: template)
        }
        return text
    }

    private static let secretPatterns: [(NSRegularExpression, String)] = [
        // Env-style upper-case names only: `private var escToken: NSObjectProtocol?` in OCR'd code is not a key.
        (#"\b([A-Z0-9_]*(?:API_?KEY|SECRET|TOKEN|PASSWORD)[A-Z0-9_]*\s*[=:]\s*(?:\\?["'])?)[A-Za-z0-9_\-./+]{12,}"#, "$1[скрыто]"),
        (#"\b(AIza[0-9A-Za-z_\-]{4})[0-9A-Za-z_\-]{12,}"#, "$1…[скрыто]"),
        (#"\b(sk-(?:ant-|proj-)?[A-Za-z0-9]{2})[A-Za-z0-9_\-]{16,}"#, "$1…[скрыто]"),
        (#"\b(gh[pousr]_[A-Za-z0-9]{2})[A-Za-z0-9]{20,}"#, "$1…[скрыто]"),
        (#"\b(xox[abpr]-[A-Za-z0-9]{2})[A-Za-z0-9\-]{10,}"#, "$1…[скрыто]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func pageName(_ number: Int) -> String { String(format: "packet-%03d.md", number) }

    /// Wimm's metadata lines before the first `--- ` text label.
    static func headerLines(_ text: String) -> [String] {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") { break }
            lines.append(String(line))
        }
        return lines
    }

    private static func value(of key: String, in header: [String]) -> String? {
        header.first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)) }
    }

    static func attention(_ header: [String]) -> [String] {
        var notes: [String] = []
        if value(of: "speech", in: header)?.hasPrefix("no_speech") == true { notes.append("speech: no_speech") }
        if let retry = value(of: "retranscription", in: header), retry.contains("no_speech") { notes.append("перерасшифровка: no_speech") }
        if let coverage = value(of: "coverage", in: header) {
            notes.append("coverage: " + (coverage.components(separatedBy: " — ").first ?? coverage))
        }
        return notes
    }
}
