import Foundation

/// A Markdown article from an externally maintained personal knowledge base.
/// The relative path is its stable identity; no parallel database is created.
public struct KnowledgeArticle: Identifiable, Equatable, Sendable {
    public let relativePath: String
    public let fileURL: URL
    public let title: String
    public let summary: String
    public let category: String
    public let content: String
    public let modifiedAt: Date

    public var id: String { relativePath }

    public var bodyWithoutTitle: String {
        var lines = content.components(separatedBy: .newlines)
        if let firstContent = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstContent].trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            lines.remove(at: firstContent)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum KnowledgeArticleStoreError: LocalizedError, Equatable {
    case articleOutsideRoot
    case articleChangedOnDisk

    public var errorDescription: String? {
        switch self {
        case .articleOutsideRoot:
            return "The article path is outside the selected Wiki folder."
        case .articleChangedOnDisk:
            return "The article changed on disk. Reload it before saving your edits."
        }
    }
}

/// Filesystem adapter for a folder of Markdown articles. It deliberately has
/// no generation, indexing, or semantic model responsibilities.
public actor KnowledgeArticleStore {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    public func loadArticles() throws -> [KnowledgeArticle] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [KnowledgeArticle] = []
        for case let url as URL in enumerator {
            guard ["md", "markdown"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            result.append(makeArticle(
                url: url,
                content: content,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }

        return result.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// Atomically replaces an article, but only if the external secretary has
    /// not changed it since the UI loaded the draft.
    public func save(_ article: KnowledgeArticle, content: String) throws -> KnowledgeArticle {
        let target = article.fileURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isInsideRoot(target) else { throw KnowledgeArticleStoreError.articleOutsideRoot }

        let currentDate = try target.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate ?? .distantPast
        guard abs(currentDate.timeIntervalSince(article.modifiedAt)) < 0.001 else {
            throw KnowledgeArticleStoreError.articleChangedOnDisk
        }

        try Data(content.utf8).write(to: target, options: .atomic)
        let newDate = try target.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate ?? Date()
        return makeArticle(url: target, content: content, modifiedAt: newDate)
    }

    private func makeArticle(url: URL, content: String, modifiedAt: Date) -> KnowledgeArticle {
        let relativePath = relativePath(for: url)
        let pathParts = relativePath.split(separator: "/").map(String.init)
        let category = pathParts.count > 1 ? pathParts[0] : "Главная"
        let title = Self.extractTitle(from: content)
            ?? url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")

        return KnowledgeArticle(
            relativePath: relativePath,
            fileURL: url,
            title: title,
            summary: Self.extractSummary(from: content),
            category: category,
            content: content,
            modifiedAt: modifiedAt
        )
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count))
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return url.path.hasPrefix(rootPath)
    }

    public nonisolated static func extractTitle(from markdown: String) -> String? {
        markdown.components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("# ") })?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public nonisolated static func extractSummary(from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var paragraph: [String] = []
        var inTable = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !paragraph.isEmpty { break }
                inTable = false
                continue
            }
            if line.hasPrefix("#") || line == "---" || line.hasPrefix("<!--") { continue }
            if line.hasPrefix("|") { inTable = true; continue }
            if inTable { continue }

            let cleaned = line.hasPrefix(">")
                ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                : line
            if cleaned.hasPrefix("- ") || cleaned.hasPrefix("* ") {
                if paragraph.isEmpty { paragraph.append(String(cleaned.dropFirst(2))) }
                break
            }
            paragraph.append(cleaned)
        }

        let value = paragraph.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 260 else { return value }
        let end = value.index(value.startIndex, offsetBy: 257)
        return String(value[..<end]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
