import ArgumentParser
import Foundation
import WimmInfrastructure

/// The secretary's side of document comments (`docs/Document_Comments.md`):
/// read the owner's comments and reactions with the text they point at, then
/// answer or close them. Only ever appends to the threads file; never edits
/// the document.
struct Comments: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "comments",
        abstract: "Read and answer comments on a Markdown document (Personal document window)",
        subcommands: [List.self, Reply.self, Status.self],
        defaultSubcommand: List.self
    )

    struct DocumentOption: ParsableArguments {
        @Argument(help: "The Markdown document the comments are on")
        var document: String

        var url: URL { URL(fileURLWithPath: (document as NSString).expandingTildeInPath).standardizedFileURL }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List threads with their section, quote and the block they land in")

        @OptionGroup var target: DocumentOption
        @Flag(name: .long, help: "Include resolved and dropped threads")
        var all = false
        @Flag(name: .long, help: "Only threads waiting for the secretary (open)")
        var pending = false
        @Flag(name: .long, help: "Print JSON")
        var json = false

        func run() async throws {
            let store = DocumentCommentStore(document: target.url)
            let snapshot = try await store.load()
            let document = try? PersonalDocument(text: String(contentsOf: target.url, encoding: .utf8))
            let threads = snapshot.threads.filter { thread in
                if pending { return thread.status == .open }
                return all || !thread.status.isClosed
            }
            let placement = document?.place(threads) ?? [:]
            let items = threads.map { thread -> Item in
                let block = placement[thread.id].flatMap { id in document?.blocks.first { $0.id == id } }
                let reaction = thread.root.intent.flatMap(DocumentReaction.init(rawValue:))
                return Item(id: thread.id, status: thread.status.rawValue, kind: thread.root.kind.rawValue,
                            reaction: thread.root.reaction, instruction: reaction?.instruction,
                            section: thread.root.section, heading: thread.root.heading,
                            quote: thread.root.quote ?? "", text: thread.root.text,
                            block: block.map { document?.displayMarkdown(for: $0) ?? $0.markdown },
                            detached: block == nil, at: thread.root.at,
                            replies: thread.replies.map { reply in
                                .init(author: reply.author,
                                      text: (reply.text ?? "") + (reply.intent.flatMap(DocumentReaction.init(rawValue:)).map { " (\($0.emoji) \($0.instruction))" } ?? ""),
                                      status: reply.status, at: reply.at)
                            })
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(decoding: try encoder.encode(items), as: UTF8.self))
            } else {
                print("\(store.location.fileURL.path) · doc \(store.location.doc) · \(items.count) thread(s)")
                for item in items {
                    print("")
                    print("[\(item.id)] \(item.status) · \(item.reaction.map { "\($0) \(item.instruction ?? "")" } ?? "comment") · \(item.heading ?? item.section ?? "—") · \(item.at)")
                    print("  quote: «\(item.quote)»")
                    if let text = item.text { print("  owner: \(text)") }
                    for reply in item.replies { print("  \(reply.author): \(reply.text)\(reply.status.map { " [\($0)]" } ?? "")") }
                    if item.detached { print("  DETACHED: the quoted text is no longer in the document") }
                    else if let block = item.block { print("  block: " + block.replacingOccurrences(of: "\n", with: "\n         ")) }
                }
            }
            if snapshot.skippedLines > 0 { FileHandle.standardError.write(Data("Skipped \(snapshot.skippedLines) invalid line(s) in the threads file.\n".utf8)) }
        }

        struct Item: Encodable {
            struct Reply: Encodable { let author: String; let text: String; let status: String?; let at: String }
            let id: String, status: String, kind: String
            let reaction: String?, instruction: String?
            let section: String?, heading: String?
            let quote: String, text: String?
            let block: String?, detached: Bool, at: String
            let replies: [Reply]
        }
    }

    struct Reply: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Append the secretary's reply to a thread")

        @OptionGroup var target: DocumentOption
        @Argument(help: "Thread id (c-…)")
        var thread: String
        @Option(name: .long, help: "Reply text")
        var text: String
        @Option(name: .long, help: "New status with the reply: answered (default), applied, resolved, dropped")
        var status: String = DocumentCommentStatus.answered.rawValue
        @Option(name: .long, help: "Author recorded on the reply")
        var author: String = DocumentCommentAuthor.secretary

        func run() async throws {
            guard let status = DocumentCommentStatus(rawValue: status), status != .open else {
                throw ValidationError("Status must be answered, applied, resolved or dropped.")
            }
            let store = try await Comments.existingThread(thread, document: target.url)
            try await store.append(store.newReply(to: thread, text: text, author: author, status: status))
            print("Replied to \(thread) (\(status.rawValue)).")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a thread's status without a reply")

        @OptionGroup var target: DocumentOption
        @Argument(help: "Thread id (c-…)")
        var thread: String
        @Argument(help: "open, answered, applied, resolved or dropped")
        var status: String
        @Option(name: .long, help: "Author recorded on the change")
        var author: String = DocumentCommentAuthor.secretary

        func run() async throws {
            guard let status = DocumentCommentStatus(rawValue: status) else {
                throw ValidationError("Unknown status \(self.status).")
            }
            let store = try await Comments.existingThread(thread, document: target.url)
            try await store.append(store.newStatus(of: thread, status, author: author))
            print("\(thread) → \(status.rawValue).")
        }
    }

    static func existingThread(_ id: String, document: URL) async throws -> DocumentCommentStore {
        let store = DocumentCommentStore(document: document)
        guard try await store.load().threads.contains(where: { $0.id == id }) else {
            throw ValidationError("No thread \(id) on \(store.location.doc) in \(store.location.fileURL.path).")
        }
        return store
    }
}
