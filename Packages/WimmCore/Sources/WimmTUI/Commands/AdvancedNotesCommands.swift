import Foundation
import WimmDomain

// MARK: - notes query / select sub-commands

extension WimmTUIRuntime {

    static func runNotes(args: [String], container: AppContainer) async throws {
        guard let sub = args.first else {
            print("Usage: notes <query|select>")
            return
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "query":  try await runNotesQuery(args: rest, container: container)
        case "select": try await runNotesSelect(args: rest, container: container)
        case "like":   try await runNotesLike(args: rest, container: container)
        default:
            print("Usage: notes <query|select|like>")
        }
    }

    // MARK: - notes query

    private static func runNotesQuery(args: [String], container: AppContainer) async throws {
        let opts = parseNotesQueryOptions(args: args)
        let query = NoteSearchQuery(
            text: opts.query.isEmpty ? nil : opts.query,
            tag: nil,
            project: opts.projectId,
            status: opts.failedOnly ? .failed(reason: "", retryable: true) : nil,
            limit: opts.limit,
            isArtifact: opts.artifactsOnly ? true : (opts.excludeArtifacts ? false : nil),
            isDraft: opts.draftsOnly ? true : nil,
            isInsight: opts.insightsOnly ? true : nil,
            isLiked: opts.favoritesOnly ? true : nil,
            isUnprocessed: opts.unprocessedOnly ? true : nil,
            isUnassigned: opts.unassignedOnly ? true : nil
        )
        let results = try await container.searchNotes.execute(query: query)
        if opts.json {
            printNotesQueryJSON(results)
        } else {
            print("Matched \(results.count) notes:")
            for n in results {
                let title = n.card?.title ?? n.title ?? "Untitled"
                let proj = n.card?.projects.first ?? "unassigned"
                print("- \(n.id.uuidString) | \(n.createdAt) | \(title) | project=\(proj)")
            }
        }
    }

    // MARK: - notes select

    private static func runNotesSelect(args: [String], container: AppContainer) async throws {
        let opts = parseNotesSelectOptions(args: args)
        guard let targetId = opts.id else {
            print("Error: provide --id <uuid>")
            return
        }
        let allNotes = try await container.listNotes.execute()
        let existing = Set(opts.selected.compactMap(UUID.init))
        let selection = opts.additive ? existing.union([targetId]) : [targetId]
        let activeNote = allNotes.first { selection.contains($0.id) }
        let targetIndex = allNotes.firstIndex { $0.id == targetId }

        if opts.json {
            let selectedArr = selection.map { "\"\($0.uuidString)\"" }.sorted().joined(separator: ", ")
            let activeStr = activeNote.map { "\"\($0.id.uuidString)\"" } ?? "null"
            let idxStr = targetIndex.map(String.init) ?? "null"
            print("{\n  \"selectedIds\": [\(selectedArr)],\n  \"activeNoteId\": \(activeStr),\n  \"targetIndex\": \(idxStr)\n}")
        } else {
            print("Selected: \(selection.map(\.uuidString).sorted().joined(separator: ", "))")
            if let active = activeNote { print("Active: \(active.id)") }
            if let idx = targetIndex { print("Target index: \(idx)") }
        }
    }

    // MARK: - JSON output

    private static func printNotesQueryJSON(_ notes: [CapturedNote]) {
        struct Row: Codable {
            let id: String; let title: String; let createdAt: Date
            let projectId: String?
            let isArtifact: Bool; let isDraft: Bool; let isInsight: Bool; let isLiked: Bool
        }
        let rows = notes.map { n in
            Row(
                id: n.id.uuidString,
                title: n.card?.title ?? n.title ?? "",
                createdAt: n.createdAt,
                projectId: n.card?.projects.first,
                isArtifact: n.card?.isArtifact ?? false,
                isDraft: n.card?.isDraft ?? false,
                isInsight: n.card?.isInsight ?? false,
                isLiked: n.card?.isLiked ?? false
            )
        }
        if let data = try? WimmTUIRuntime.prettyJSONEncoder.encode(rows),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
    }

    // MARK: - Parsing helpers

    /// Options parsed from `notes query` CLI arguments.
    struct NotesQueryOptions {
        var query: String = ""
        var failedOnly: Bool = false
        var insightsOnly: Bool = false
        var favoritesOnly: Bool = false
        var draftsOnly: Bool = false
        var artifactsOnly: Bool = false
        var excludeArtifacts: Bool = false
        var unprocessedOnly: Bool = false
        var unassignedOnly: Bool = false
        var projectId: String? = nil
        var limit: Int = 50
        var json: Bool = false
    }

    /// Options parsed from `notes select` CLI arguments.
    struct NotesSelectOptions {
        var id: UUID? = nil
        var selected: [String] = []
        var additive: Bool = false
        var json: Bool = false
    }

    static func parseNotesQueryOptions(args: [String]) -> NotesQueryOptions {
        let p = ArgParser(args)
        return NotesQueryOptions(
            query:            p.string(anyOf: "--query", "-q") ?? "",
            failedOnly:       p.flag(anyOf: "--failed", "--failed-only"),
            insightsOnly:     p.flag(anyOf: "--insights", "--insights-only"),
            favoritesOnly:    p.flag(anyOf: "--favorites", "--favorites-only", "--liked"),
            draftsOnly:       p.flag(anyOf: "--drafts", "--drafts-only"),
            artifactsOnly:    p.flag(anyOf: "--artifacts", "--artifacts-only"),
            excludeArtifacts: p.flag("--no-artifacts"),
            unprocessedOnly:  p.flag(anyOf: "--unprocessed", "--unprocessed-only"),
            unassignedOnly:   p.flag(anyOf: "--unassigned", "--unassigned-only"),
            projectId:        p.string(anyOf: "--project-id", "--project"),
            limit:            p.int(anyOf: "--limit", "-l") ?? 50,
            json:             p.flag("--json")
        )
    }

    static func parseNotesSelectOptions(args: [String]) -> NotesSelectOptions {
        let p = ArgParser(args)
        let selected = p.string("--selected")
            .map { $0.split(separator: ",").map(String.init) } ?? []
        return NotesSelectOptions(
            id:       p.string("--id").flatMap(UUID.init),
            selected: selected,
            additive: p.flag("--additive"),
            json:     p.flag("--json")
        )
    }

    // MARK: - Write helpers

    /// Resolves exactly one note by id prefix, then invokes `action`.
    /// Prints a user-facing error if 0 or >1 matches are found.
    private static func withUniqueNote(
        prefix: String,
        container: AppContainer,
        action: (CapturedNote) async throws -> Void
    ) async throws {
        let all = try await container.storage.loadAll()
        let lower = prefix.lowercased()
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
        switch matches.count {
        case 0:
            print("No note found with id prefix '\(prefix)'.")
        case 1:
            try await action(matches[0])
        default:
            print("Ambiguous prefix '\(prefix)' matches \(matches.count) notes. Provide a longer prefix.")
            for n in matches { print("  \(n.id.uuidString)") }
        }
    }

    /// `notes like <id-prefix>` — toggles `isLiked` on the matched note's AnalysisCard.
    private static func runNotesLike(args: [String], container: AppContainer) async throws {
        guard let prefix = args.first, !prefix.isEmpty else {
            print("Usage: notes like <id-prefix>")
            return
        }
        try await withUniqueNote(prefix: prefix, container: container) { note in
            guard note.card != nil else {
                print("Note \(note.id.uuidString) has no NoteCard yet (unprocessed). Cannot toggle like.")
                return
            }
            var updated = note
            let newValue = !(updated.card?.isLiked ?? false)
            updated.card?.isLiked = newValue
            try await container.storage.updateNote(updated)
            print("\(updated.id.uuidString): isLiked = \(newValue)")
        }
    }

    /// `delete <id-prefix>` — permanently removes a note and its associated files.
    static func runDelete(args: [String], container: AppContainer) async throws {
        guard let prefix = args.first, !prefix.isEmpty else {
            print("Usage: delete <id-prefix>")
            return
        }
        try await withUniqueNote(prefix: prefix, container: container) { note in
            try await container.storage.deleteNote(id: note.id)
            let title = note.card?.title ?? note.title ?? note.id.uuidString
            print("Deleted: \(note.id.uuidString) (\(title))")
        }
    }
}
