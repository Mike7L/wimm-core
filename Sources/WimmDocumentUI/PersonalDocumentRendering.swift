import AppKit
import Foundation

@MainActor
public enum PersonalDocumentRendering {
    public struct Style: Equatable {
        public init(scale: CGFloat = 1, text: NSColor = .labelColor, secondary: NSColor = .secondaryLabelColor, link: NSColor = .linkColor) {
            self.scale = scale; self.text = text; self.secondary = secondary; self.link = link
        }
        public var scale: CGFloat
        public var text: NSColor
        public var secondary: NSColor
        public var link: NSColor
    }

    public static func attributed(_ markdown: String, baseURL: URL?, style: Style) -> NSAttributedString? {
        let key = "wimm|\(baseURL?.absoluteString ?? "")|\(style.scale)|\(style.text)|\(style.secondary)|\(style.link)|\(markdown)"
        return DocumentRenderCache.attributed(key: key) { uncachedAttributed(markdown, baseURL: baseURL, style: style) }
    }

    private static func uncachedAttributed(_ markdown: String, baseURL: URL?, style: Style) -> NSAttributedString? {
        let blocks = MarkdownDocumentParser.parse(markdown)
        guard !blocks.isEmpty else { return nil }
        let result = NSMutableAttributedString()
        let bodySize = DocumentReadingLayout.bodyFontSize * style.scale
        for (index, block) in blocks.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: bodySize)])) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6 * style.scale
            paragraph.paragraphSpacing = 10 * style.scale
            switch block {
            case .heading(let level, let text):
                let size = DocumentReadingLayout.headingSize(level)
                let font = NSFont.systemFont(ofSize: size * style.scale, weight: level <= 2 ? .bold : .semibold)
                result.append(inline(text, baseURL: baseURL, font: font, color: style.text, paragraph: paragraph, style: style))
            case .paragraph(let text):
                result.append(inline(text, baseURL: baseURL, font: .systemFont(ofSize: bodySize), color: style.text, paragraph: paragraph, style: style))
            case .quote(let text):
                paragraph.firstLineHeadIndent = 14 * style.scale
                paragraph.headIndent = 14 * style.scale
                result.append(inline(text, baseURL: baseURL, font: .systemFont(ofSize: bodySize), color: style.secondary, paragraph: paragraph, style: style))
            case .list(let items):
                for (itemIndex, item) in items.enumerated() {
                    if itemIndex > 0 { result.append(NSAttributedString(string: "\n")) }
                    let itemStyle = NSMutableParagraphStyle()
                    itemStyle.lineSpacing = 6 * style.scale
                    itemStyle.paragraphSpacing = 6 * style.scale
                    let indent = (CGFloat(item.indentation) * 18 + 26) * style.scale
                    itemStyle.firstLineHeadIndent = CGFloat(item.indentation) * 18 * style.scale
                    itemStyle.headIndent = indent
                    itemStyle.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                    let marker: String
                    switch item.marker {
                    case .bullet: marker = "•"
                    case .ordered(let value): marker = value
                    case .task(let done): marker = done ? "☑" : "☐"
                    }
                    let font = NSFont.systemFont(ofSize: bodySize)
                    result.append(NSAttributedString(string: marker + "\t", attributes: [.font: font, .foregroundColor: style.secondary, .paragraphStyle: itemStyle]))
                    result.append(inline(item.content, baseURL: baseURL, font: font, color: style.text, paragraph: itemStyle, style: style))
                }
            case .rule:
                result.append(NSAttributedString(string: "———", attributes: [.font: NSFont.systemFont(ofSize: bodySize), .foregroundColor: style.secondary, .paragraphStyle: paragraph]))
            case .table, .code:
                return nil
            }
        }
        return result
    }

    /// The secretary's reservations ("not confirmed", "unclear") are written as
    /// `^[…]` (a Pandoc inline note) so they read as comments of the editor, not
    /// as the document's own statements. Brackets nest: `^[… [S205] …]`.
    public static func splitAsides(_ text: String) -> [(text: String, isAside: Bool)] {
        var pieces: [(String, Bool)] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("^["), let close = matchingBracket(in: text, open: text.index(after: index)) {
                if !plain.isEmpty { pieces.append((plain, false)); plain = "" }
                let inner = String(text[text.index(index, offsetBy: 2)..<close]).trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { pieces.append((inner, true)) }
                index = text.index(after: close)
            } else {
                plain.append(text[index])
                index = text.index(after: index)
            }
        }
        if !plain.isEmpty { pieces.append((plain, false)) }
        return pieces
    }

    private static func matchingBracket(in text: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            switch text[index] {
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func inline(_ text: String, baseURL: URL?, font: NSFont, color: NSColor,
                               paragraph: NSParagraphStyle, style: Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in splitAsides(text) {
            if piece.isAside {
                let asideFont = NSFont.systemFont(ofSize: font.pointSize * 0.86)
                let body = inlineRuns(piece.text, baseURL: baseURL, font: asideFont, color: style.secondary, paragraph: paragraph, style: style)
                let aside = NSMutableAttributedString(string: "\u{2009}", attributes: [.font: asideFont])
                aside.append(body)
                aside.append(NSAttributedString(string: "\u{2009}", attributes: [.font: asideFont]))
                aside.addAttributes([
                    .backgroundColor: style.secondary.withAlphaComponent(0.12),
                    .paragraphStyle: paragraph,
                    asideKey: true,
                ], range: NSRange(location: 0, length: aside.length))
                result.append(NSAttributedString(string: " ", attributes: [.font: font, .paragraphStyle: paragraph]))
                result.append(aside)
            } else {
                result.append(inlineRuns(piece.text, baseURL: baseURL, font: font, color: color, paragraph: paragraph, style: style))
            }
        }
        return result
    }

    /// Marks a run as the secretary's aside (tests, future hide toggle).
    public static let asideKey = NSAttributedString.Key("wimm.secretaryAside")

    private static func inlineRuns(_ text: String, baseURL: URL?, font: NSFont, color: NSColor,
                                   paragraph: NSParagraphStyle, style: Style) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: text, options: options, baseURL: baseURL)) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: paragraph]
            if let intent = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    runFont = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)), size: font.pointSize) ?? font
                }
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: 13 * style.scale, weight: .regular)
                    attributes[.foregroundColor] = NSColor.systemOrange
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = style.link
            }
            attributes[.font] = runFont
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }
}

