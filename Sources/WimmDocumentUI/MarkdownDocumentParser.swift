import Foundation

/// Small, deterministic block parser for the Markdown subset used by the
/// reviewable Wiki projection. Foundation's `AttributedString` handles inline
/// emphasis and links; this parser preserves the block structure that SwiftUI
/// `Text` otherwise flattens.
public enum MarkdownRenderBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case quote(String)
    case table(header: [String], rows: [[String]])
    case rule
    case code(language: String?, content: String)
}

public struct MarkdownListItem: Equatable {
    public init(indentation: Int, marker: Marker, content: String) {
        self.indentation = indentation; self.marker = marker; self.content = content
    }
    public enum Marker: Equatable {
        case bullet
        case ordered(String)
        case task(isComplete: Bool)
    }

    public let indentation: Int
    public let marker: Marker
    public var content: String
}

public enum MarkdownDocumentParser {
    public static func parse(_ markdown: String) -> [MarkdownRenderBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownRenderBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if let fence = codeFence(in: trimmed) {
                let language = String(trimmed.dropFirst(fence.count))
                    .trimmingCharacters(in: .whitespaces)
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(
                    language: language.isEmpty ? nil : language,
                    content: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(in: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let header = tableCells(in: line),
               isTableDelimiter(lines[index + 1]) {
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let row = tableCells(in: lines[index]) {
                    rows.append(row)
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let firstItem = listItem(in: line) {
                var items = [firstItem]
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if let item = listItem(in: candidate) {
                        items.append(item)
                        index += 1
                        continue
                    }
                    let leading = leadingWhitespaceCount(candidate)
                    guard leading > 0, !items.isEmpty else { break }
                    items[items.count - 1].content += " " + candidate.trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                blocks.append(.list(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(joinSoftLines(quoteLines)))
                continue
            }

            var paragraphLines: [String] = []
            while index < lines.count {
                let candidate = lines[index]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                guard !candidateTrimmed.isEmpty,
                      !startsBlock(at: index, in: lines) else { break }
                paragraphLines.append(candidate)
                index += 1
            }
            if paragraphLines.isEmpty {
                // Defensive progress for uncommon Markdown constructs that are
                // intentionally treated as ordinary text.
                paragraphLines.append(line)
                index += 1
            }
            blocks.append(.paragraph(joinSoftLines(paragraphLines)))
        }

        return blocks
    }

    private static func startsBlock(at index: Int, in lines: [String]) -> Bool {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        return codeFence(in: trimmed) != nil
            || heading(in: trimmed) != nil
            || isRule(trimmed)
            || listItem(in: lines[index]) != nil
            || trimmed.hasPrefix(">")
            || (index + 1 < lines.count
                && tableCells(in: lines[index]) != nil
                && isTableDelimiter(lines[index + 1]))
    }

    private static func joinSoftLines(_ lines: [String]) -> String {
        var result = ""
        var previousKeepsLineBreak = false
        for line in lines {
            let value = line.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            if !result.isEmpty {
                result += previousKeepsLineBreak ? "\n" : " "
            }
            result += value
            previousKeepsLineBreak = line.hasSuffix("  ")
        }
        return result
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let markerEnd = line.index(line.startIndex, offsetBy: level)
        guard markerEnd < line.endIndex, line[markerEnd].isWhitespace else { return nil }
        let text = line[markerEnd...].trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func codeFence(in line: String) -> String? {
        if line.hasPrefix("```") { return "```" }
        if line.hasPrefix("~~~") { return "~~~" }
        return nil
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func listItem(in line: String) -> MarkdownListItem? {
        let whitespaceCharacters = line.prefix(while: { $0 == " " || $0 == "\t" })
        let leading = leadingWhitespaceCount(line)
        let contentStart = line.index(line.startIndex, offsetBy: whitespaceCharacters.count)
        let remainder = String(line[contentStart...])
        let indentation = leading / 2

        if remainder.count >= 2,
           let marker = remainder.first,
           "-*+".contains(marker),
           remainder.dropFirst().first?.isWhitespace == true {
            var content = String(remainder.dropFirst(2))
            if content.hasPrefix("[ ] ") {
                content.removeFirst(4)
                return MarkdownListItem(
                    indentation: indentation,
                    marker: .task(isComplete: false),
                    content: content
                )
            }
            if content.lowercased().hasPrefix("[x] ") {
                content.removeFirst(4)
                return MarkdownListItem(
                    indentation: indentation,
                    marker: .task(isComplete: true),
                    content: content
                )
            }
            return MarkdownListItem(
                indentation: indentation,
                marker: .bullet,
                content: content
            )
        }

        let digits = remainder.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count < remainder.count else { return nil }
        let delimiterIndex = remainder.index(remainder.startIndex, offsetBy: digits.count)
        guard remainder[delimiterIndex] == "." || remainder[delimiterIndex] == ")" else { return nil }
        let afterDelimiter = remainder.index(after: delimiterIndex)
        guard afterDelimiter < remainder.endIndex, remainder[afterDelimiter].isWhitespace else { return nil }
        let textStart = remainder.index(after: afterDelimiter)
        return MarkdownListItem(
            indentation: indentation,
            marker: .ordered(String(digits) + String(remainder[delimiterIndex])),
            content: String(remainder[textStart...])
        )
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix(while: { $0 == " " || $0 == "\t" })
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func tableCells(in line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }
        var body = trimmed
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return cells.count > 1 ? cells : nil
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard let cells = tableCells(in: line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
}
