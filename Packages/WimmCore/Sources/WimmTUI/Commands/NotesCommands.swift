import Foundation
import WimmDomain

// MARK: - list / read / search commands

extension WimmTUIRuntime {

    static func runList(args: [String], container: AppContainer) async throws {
        let opts = parseListOptions(args: args)
        let notes = try await container.listNotes.execute()
        let limited = opts.limit.map { Array(notes.prefix($0)) } ?? notes
        if opts.json {
            printNotesJSON(limited)
        } else if limited.isEmpty {
            print("No notes found.")
        } else {
            for note in limited {
                print("[\(note.shortID)] \(note.createdAt) - \(note.status)")
                if case let .failed(reason, retryable) = note.status {
                    print("  Failed reason: \(reason)")
                    print("  Retryable: \(retryable)")
                }
                if !note.text.isEmpty {
                    print("  Text: \(note.text.prefix(60))...")
                }
            }
        }
    }

    static func runRead(args: [String], container: AppContainer) async throws {
        guard let prefix = args.first else {
            print("Usage: read <id_prefix>")
            return
        }
        guard let note = try await container.readNote.execute(idPrefix: prefix) else {
            print("Note not found for prefix: \(prefix)")
            return
        }
        print("ID: \(note.id)")
        print("Created: \(note.createdAt)")
        print("Status: \(note.status)")
        if let title = note.title { print("Title: \(title)") }
        print("Text:\n\(note.text)")
    }

    static func runSearch(args: [String], container: AppContainer) async throws {
        let opts = parseSearchOptions(args: args)
        let query = NoteSearchQuery(
            text: opts.text,
            tag: opts.tag,
            project: opts.project,
            status: opts.status,
            limit: opts.limit
        )
        let results = try await container.searchNotes.execute(query: query)
        if opts.json {
            printNotesJSON(results)
        } else if results.isEmpty {
            print("No notes matched.")
        } else {
            print("Found \(results.count) note(s):")
            for note in results {
                let cardTitle = note.card?.title ?? "-"
                let tags = note.card?.tags.joined(separator: ", ") ?? ""
                print("  [\(note.shortID)] \(note.createdAt) [\(note.status)] \(cardTitle)")
                if !tags.isEmpty { print("    tags: \(tags)") }
                if !note.text.isEmpty { print("    text: \(note.text.prefix(60))...") }
            }
        }
    }

    // MARK: - Shared output

    static let prettyJSONEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func printNotesJSON(_ notes: [CapturedNote]) {
        if let data = try? Self.prettyJSONEncoder.encode(notes),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        } else {
            print("[]")
        }
    }

    // MARK: - Parsing helpers

    struct ListOptions {
        var limit: Int? = nil
        var json: Bool = false
    }

    struct SearchOptions {
        var text: String? = nil
        var tag: String? = nil
        var project: String? = nil
        var status: ProcessingStatus? = nil
        var limit: Int? = nil
        var json: Bool = false
    }

    static func parseListOptions(args: [String]) -> ListOptions {
        let p = ArgParser(args)
        return ListOptions(limit: p.int("--limit").map { max(0, $0) }, json: p.flag("--json"))
    }

    static func parseSearchOptions(args: [String]) -> SearchOptions {
        let p = ArgParser(args)
        let statusStr = p.string("--status")?.lowercased()
        let status: ProcessingStatus? = statusStr.flatMap {
            switch $0 {
            case "completed":                   return .completed
            case "pending", "pending_analysis": return .pendingAnalysis
            case "failed":                      return .failed(reason: "", retryable: true)
            default:                            return nil
            }
        }
        return SearchOptions(
            text:    p.string("--text"),
            tag:     p.string("--tag"),
            project: p.string("--project"),
            status:  status,
            limit:   p.int("--limit"),
            json:    p.flag("--json")
        )
    }
}
