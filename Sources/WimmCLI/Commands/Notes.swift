import ArgumentParser
import WimmTUI
import Foundation

struct Notes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Notes query and selection tools",
        subcommands: [NotesQuery.self, NotesSelect.self, NotesSplitAttachments.self, NotesLostToText.self, NotesImportVoiceMemos.self, NotesMergeVoiceMemosDuplicates.self, NotesFillVoiceMemosFields.self]
    )
}

struct NotesQuery: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "Filter notes with Reader-compatible query rules"
    )

    @Option(name: .shortAndLong, help: "Free-text query")
    var query: String = ""

    @Flag(name: .long, help: "Keep only notes that match --query in text")
    var onlyMatches: Bool = false

    @Flag(name: .long, help: "Keep only failed notes")
    var failedOnly: Bool = false

    @Flag(name: .long, help: "Keep only notes with screenshot")
    var withShotOnly: Bool = false

    @Flag(name: .long, help: "Keep only insight notes")
    var insightsOnly: Bool = false

    @Flag(name: .long, help: "Keep only favorite notes")
    var favoritesOnly: Bool = false

    @Flag(name: .long, help: "Keep only draft notes (excluding artifacts)")
    var draftsOnly: Bool = false

    @Flag(name: .long, help: "Keep only artifact notes")
    var artifactsOnly: Bool = false

    @Flag(name: .long, help: "Keep only unprocessed notes")
    var unprocessedOnly: Bool = false

    @Flag(name: .long, help: "Include artifacts in normal listing")
    var includeArtifacts: Bool = false

    @Flag(name: .long, help: "Include canceled notes")
    var includeCanceled: Bool = false

    @Option(name: .shortAndLong, help: "Maximum number of rows to print")
    var limit: Int = 50

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        var args = ["notes", "query"]
        if !query.isEmpty { args += ["--query", query] }
        if failedOnly { args.append("--failed") }
        if insightsOnly { args.append("--insights") }
        if favoritesOnly { args.append("--favorites") }
        if draftsOnly { args.append("--drafts") }
        if artifactsOnly { args.append("--artifacts") }
        if unprocessedOnly { args.append("--unprocessed") }
        args += ["--limit", "\(max(0, limit))"]
        if json { args.append("--json") }
        try await WimmTUIRuntime.runOnce(args)
    }
}

struct NotesSelect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select",
        abstract: "Apply note selection rules used by Reader UI"
    )

    @Option(name: .long, parsing: .upToNextOption, help: "Current selected IDs before update")
    var selected: [String] = []

    @Option(name: .long, help: "Target note ID to select")
    var id: String?

    @Flag(name: .long, help: "Add target ID to existing selection instead of replacing it")
    var additive: Bool = false

    @Flag(name: .long, help: "Resolve active note in output")
    var open: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    func run() async throws {
        guard let id else {
            throw ValidationError("Provide --id <note-uuid>.")
        }
        guard UUID(uuidString: id) != nil else {
            throw ValidationError("Invalid UUID for --id: \(id)")
        }

        var args = ["notes", "select", "--id", id]
        if !selected.isEmpty { args += ["--selected", selected.joined(separator: ",")] }
        if additive { args.append("--additive") }
        if json { args.append("--json") }
        try await WimmTUIRuntime.runOnce(args)
    }
}
