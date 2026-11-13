import SwiftUI

private struct MarkdownTextSelection: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) }
        else { content.textSelection(.disabled) }
    }
}

/// A view that renders Markdown content with proper styling.
/// Supports headers, bold, italic, code blocks, links, lists, etc.
public struct MarkdownTextView: View {
    public init(content: String, baseURL: URL? = nil, allowsTextSelection: Bool = true, scale: CGFloat = 1) {
        self.content = content; self.baseURL = baseURL; self.allowsTextSelection = allowsTextSelection; self.scale = scale
    }
    let content: String
    var baseURL: URL? = nil
    var allowsTextSelection = true
    /// Text zoom; every size below is multiplied by it.
    var scale: CGFloat = 1

    /// Reading size for running text; the system body (13 pt) is a UI size.
    public static let bodyFontSize = DocumentReadingLayout.bodyFontSize

    public var body: some View {
        VStack(alignment: .leading, spacing: 16 * scale) {
            ForEach(Array(MarkdownDocumentParser.parse(content).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownRenderBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(attributedString(from: text))
                .font(headingFont(level))
                .padding(.top, (level <= 2 ? 8 : 3) * scale)
                .modifier(MarkdownTextSelection(enabled: allowsTextSelection))
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            markdownText(text)
        case .list(let items):
            VStack(alignment: .leading, spacing: 8 * scale) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        listMarker(item.marker)
                            .font(.system(size: Self.bodyFontSize * scale))
                            .frame(width: 22 * scale, alignment: .trailing)
                        markdownText(item.content)
                    }
                    .padding(.leading, CGFloat(item.indentation) * 18 * scale)
                }
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 3)
                markdownText(text)
                    .foregroundStyle(.secondary)
            }
            // The bar is greedy; without this a quote grows into any spare height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        case .table(let header, let rows):
            markdownTable(header: header, rows: rows)
        case .rule:
            Divider()
                .padding(.vertical, 4)
        case .code(let language, let content):
            CodeBlockView(language: language, code: content, allowsTextSelection: allowsTextSelection, scale: scale)
        }
    }

    private func markdownText(_ text: String) -> some View {
        Text(attributedString(from: text))
            .font(.system(size: Self.bodyFontSize * scale))
            .lineSpacing(6 * scale)
            .modifier(MarkdownTextSelection(enabled: allowsTextSelection))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func listMarker(_ marker: MarkdownListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
        case .ordered(let value):
            Text(value)
        case .task(let isComplete):
            Image(systemName: isComplete ? "checkmark.square.fill" : "square")
                .foregroundStyle(isComplete ? Color.accentColor : Color.secondary)
        }
    }

    private func markdownTable(header: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                tableRow(header, isHeader: true)
                Divider()
                    .gridCellColumns(maximumColumnCount(header: header, rows: rows))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    tableRow(row, isHeader: false)
                }
            }
            .padding(12)
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tableRow(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(attributedString(from: cell))
                    .font(.system(size: Self.bodyFontSize * scale, weight: isHeader ? .semibold : .regular))
                    .modifier(MarkdownTextSelection(enabled: allowsTextSelection))
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func maximumColumnCount(header: [String], rows: [[String]]) -> Int {
        max(header.count, rows.map(\.count).max() ?? 1)
    }

    private func headingFont(_ level: Int) -> Font {
        .system(size: DocumentReadingLayout.headingSize(level) * scale,
                weight: level <= 2 ? .bold : .semibold)
    }

    private func attributedString(from text: String) -> AttributedString {
        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .full
            var attributed = try AttributedString(markdown: text, options: options, baseURL: baseURL)

            // Block structure is rendered by this view; AttributedString keeps
            // responsibility for inline emphasis, code, and links.
            for run in attributed.runs {
                let range = run.range
                if run.inlinePresentationIntent?.contains(.code) == true {
                    attributed[range].foregroundColor = .orange
                    attributed[range].backgroundColor = Color(nsColor: .controlBackgroundColor)
                    attributed[range].font = .system(size: 13 * scale, design: .monospaced)
                }
            }

            return attributed
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Code Block View

struct CodeBlockView: View {
    let language: String?
    let code: String
    var allowsTextSelection = true
    var scale: CGFloat = 1
    
    @State private var isCopied = false
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language and copy button
            HStack {
                if let language = language, !language.isEmpty {
                    Text(language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.caption2)
                    }
                    .foregroundStyle(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(headerBackground)
            
            // Code content
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 12 * scale, design: .monospaced))
                    .foregroundStyle(.primary)
                    .modifier(MarkdownTextSelection(enabled: allowsTextSelection))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(codeBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
    }
    
    private var headerBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.15)
            : Color(white: 0.9)
    }
    
    private var codeBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.1)
            : Color(white: 0.95)
    }
    
    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.1)
    }
    
    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        
        withAnimation {
            isCopied = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                isCopied = false
            }
        }
    }
}

